#!/bin/bash
# scripts/verify-observability.sh
#
# Asserts that the monitoring plane matches the design, the way
# verify-jenkins.sh does for the CI/CD plane. Read-only: it changes nothing.
#
# The rule this file is written to, taken from the phase 4 review: A WEAKER
# CHECK MUST NEVER BE ALLOWED TO LOOK LIKE A STRONGER ONE. Every assertion here
# fails on the thing it names. Where a check cannot be made -- because a tool is
# absent or a target has legitimately not scraped yet -- it says SKIP out loud
# and is counted separately. A skip is never reported as a pass.
set -uo pipefail

NAMESPACE="${NAMESPACE:-observability}"
APP_NS="${APP_NS:-devops-app}"
JENKINS_NS="${JENKINS_NS:-jenkins}"

PASS=0; FAIL=0; SKIP=0; PENDING=0
FAILED=()
NOT_DEPLOYED=()

ok()   { echo "  [ OK ]  $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL]  $1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
skip() { echo "  [SKIP]  $1"; SKIP=$((SKIP+1)); }
# A FOURTH outcome, and it earns its place.
#
# deploy.sh does not deploy the application -- the CD pipeline does. So on a
# first deploy this script found no ServiceMonitors, no app NetworkPolicy, no
# `up` series and no app_build_info, and reported EIGHT FAILURES. All eight were
# true statements about a cluster in a perfectly normal state.
#
# That is worse than a wrong check. Eight red lines on every first run teaches
# you to skim the failure list, and the whole value of this script is that
# someone reads it. "Not deployed yet" is not a pass and not a defect; it is a
# third thing, and it needs saying as a third thing.
pending() { echo "  [....]  $1 — the application is not deployed yet"
            PENDING=$((PENDING+1)); NOT_DEPLOYED+=("$1"); }

# Is the application actually deployed? Asked once, by looking for the
# Deployments the CD pipeline creates, and used to route the checks below.
APP_DEPLOYED=0
if [ "$(kubectl get deployment -n "$APP_NS" -o name 2>/dev/null | wc -l)" -gt 0 ]; then
    APP_DEPLOYED=1
fi

check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

echo "=================================================="
echo "  Verifying observability"
echo "=================================================="

# ---------------------------------------------------------------- workloads
echo ""
echo "-- workloads --"
check "namespace ${NAMESPACE} exists" kubectl get namespace "$NAMESPACE"
check "Prometheus StatefulSet is ready" bash -c \
  "[ \"\$(kubectl get statefulset -n $NAMESPACE -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.readyReplicas}')\" = '1' ]"
check "Alertmanager StatefulSet is ready" bash -c \
  "[ \"\$(kubectl get statefulset -n $NAMESPACE -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].status.readyReplicas}')\" = '1' ]"
check "Grafana Deployment is available" bash -c \
  "[ \"\$(kubectl get deployment -n $NAMESPACE -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.availableReplicas}')\" = '1' ]"
check "kube-state-metrics is available" bash -c \
  "kubectl get deployment -n $NAMESPACE -l app.kubernetes.io/name=kube-state-metrics -o jsonpath='{.items[0].status.availableReplicas}' | grep -q '[1-9]'"

# node-exporter on EVERY node. This is the check that catches the DaemonSet
# tolerations trap: with the chart's defaults it comes up healthy, reports no
# error, and simply skips the two tainted nodes.
NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
NE_READY=$(kubectl get daemonset -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus-node-exporter \
    -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo 0)
if [ "$NODES" -gt 0 ] && [ "$NE_READY" = "$NODES" ]; then
    ok "node-exporter runs on all ${NODES} nodes"
else
    bad "node-exporter runs on ${NE_READY} of ${NODES} nodes (tainted nodes need tolerations: [{operator: Exists}])"
fi

# ------------------------------------------------------------- placement
echo ""
echo "-- placement --"
# Everything except node-exporter must be on the monitoring node group, or the
# whole reason for a third node group is gone.
PLACEMENT=$(kubectl get pods -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/name}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
    | grep -v '^prometheus-node-exporter ' | grep -v '^ ')
POD_COUNT=$(printf '%s' "$PLACEMENT" | grep -c . || true)
OFF_NODE=$(printf '%s\n' "$PLACEMENT" | awk 'NF{print $2}' | sort -u | grep -c . || true)
# AUDIT FIX -- zero pods used to PASS this check.
#
# `wc -l` on empty input is 0, and 0 satisfies `-le 1`, so an empty namespace,
# a wrong context, or a kubectl that simply failed all printed "the monitoring
# plane is on a single node group". The check was strongest exactly when there
# was nothing to check. Counting the pods first makes "nothing to look at" its
# own answer instead of a pass.
if [ "${POD_COUNT:-0}" -eq 0 ]; then
    bad "no pods found in ${NAMESPACE} — placement could not be checked (this is not a pass)"
elif [ "${OFF_NODE:-0}" -le 1 ]; then
    ok "the monitoring plane is on a single node group (${POD_COUNT} pods)"
else
    bad "monitoring pods are spread across ${OFF_NODE} nodes — check nodeSelector/tolerations"
fi

# ------------------------------------------------------------- exposure
echo ""
echo "-- exposure --"
# AUDIT FIX, applied to all three negative assertions in this section.
#
# "Prove that X is ABSENT" is the one assertion shape that passes when the
# question could not be asked at all. `kubectl ... | grep -q something-bad`
# finds nothing when kubectl errors, when the context is wrong, when the
# namespace does not exist, or when RBAC denies the read -- and every one of
# those printed a green tick saying Prometheus was not exposed.
#
# Since this script runs `set -uo pipefail` WITHOUT -e, nothing aborted either.
# So each negative check now proves it could read the objects first, and a
# failed read is its own outcome rather than evidence of absence.
INGRESS_JSON=$(kubectl get ingress -n "$NAMESPACE" -o json 2>/dev/null)
if [ -z "$INGRESS_JSON" ]; then
    bad "could not read Ingresses in ${NAMESPACE} — exposure could not be verified (this is not a pass)"
else
    # AUDIT FIX -- this asked whether any Ingress NAME CONTAINED the substring
    # "prometheus" or "alertmanager". Grafana's Ingress is called
    # kube-prometheus-stack-grafana, so the check failed on every healthy
    # install, reporting that Prometheus was exposed when it was not.
    #
    # A security check that cries wolf is worse than none: it is the one you
    # learn to skim past, so the day it is right you do not read it either.
    #
    # It now asks what it means to ask -- does any Ingress ROUTE TO the
    # Prometheus or Alertmanager Service? -- by looking at backend service
    # names, which is what actually determines exposure. Grafana's Ingress
    # routes to kube-prometheus-stack-grafana and is correctly ignored.
    EXPOSED=$(printf '%s' "$INGRESS_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
bad = []
for item in d.get('items', []):
    name = item['metadata']['name']
    for rule in item.get('spec', {}).get('rules', []) or []:
        for path in (rule.get('http', {}) or {}).get('paths', []) or []:
            svc = ((path.get('backend', {}) or {}).get('service', {}) or {}).get('name', '')
            if svc.endswith('-prometheus') or svc.endswith('-alertmanager'):
                bad.append(f'{name} -> {svc}')
    dflt = ((item.get('spec', {}).get('defaultBackend', {}) or {}).get('service', {}) or {}).get('name', '')
    if dflt.endswith('-prometheus') or dflt.endswith('-alertmanager'):
        bad.append(f'{name} -> {dflt}')
print('; '.join(bad))
" 2>/dev/null)
    if [ -n "$EXPOSED" ]; then
        bad "an Ingress routes to Prometheus or Alertmanager (${EXPOSED}) — neither has ANY authentication"
    else
        ok "no Ingress routes to Prometheus or Alertmanager"
    fi
fi
check "Grafana has an Ingress" bash -c \
  "kubectl get ingress -n $NAMESPACE -o name | grep -q grafana"
check "Grafana's Ingress restricts inbound CIDRs" bash -c \
  "kubectl get ingress -n $NAMESPACE -o json | grep -q 'inbound-cidrs'"
if [ -z "$INGRESS_JSON" ]; then
    bad "could not read Ingresses in ${NAMESPACE} — placeholders could not be checked"
elif printf '%s' "$INGRESS_JSON" | grep -q 'PLACEHOLDER_'; then
    bad "a PLACEHOLDER_ value reached the cluster — install-observability.sh should have substituted it"
else
    ok "no unsubstituted placeholders in the Ingress"
fi

# The same shape once more: `! ... | grep -q 'enabled = true'` was satisfied by
# a Grafana ConfigMap that could not be read, so a missing ConfigMap reported
# "anonymous access is disabled". The setting has to be READ and found false.
GRAFANA_INI=$(kubectl get cm -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o yaml 2>/dev/null)
if [ -z "$GRAFANA_INI" ] || ! printf '%s' "$GRAFANA_INI" | grep -q 'auth.anonymous'; then
    bad "could not read Grafana's auth.anonymous setting — it was NOT verified as disabled"
elif printf '%s' "$GRAFANA_INI" | grep -A2 'auth.anonymous' | grep -q 'enabled = true'; then
    bad "Grafana anonymous access is ENABLED"
else
    ok "Grafana anonymous access is disabled"
fi

# ------------------------------------------------------------- storage
echo ""
echo "-- storage --"
check "gp3 StorageClass exists" kubectl get storageclass gp3
# AUDIT FIX -- this had no label selector, so it asked "is ANY PVC in the
# namespace Bound". Alertmanager's 1Gi claim alone satisfied it while
# Prometheus's 20Gi claim sat Pending for want of a zone or a CSI driver, and
# the check reported "Prometheus PVC is Bound". The retention check on the very
# next line already selects properly; this one did not.
check "Prometheus PVC is Bound" bash -c \
  "kubectl get pvc -n $NAMESPACE -l app.kubernetes.io/name=prometheus \
     -o jsonpath='{.items[*].status.phase}' | grep -q Bound"
check "Prometheus retention is set" bash -c \
  "kubectl get prometheus -n $NAMESPACE -o jsonpath='{.items[0].spec.retention}' | grep -q d"
# retentionSize BELOW the volume size. Equal or above and Prometheus fills the
# disk and wedges.
RS=$(kubectl get prometheus -n "$NAMESPACE" -o jsonpath='{.items[0].spec.retentionSize}' 2>/dev/null | tr -dc '0-9')
VS=$(kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus \
      -o jsonpath='{.items[0].spec.resources.requests.storage}' 2>/dev/null | tr -dc '0-9')
if [ -n "$RS" ] && [ -n "$VS" ] && [ "$RS" -lt "$VS" ]; then
    ok "retentionSize (${RS}GB) is below the volume size (${VS}Gi)"
else
    bad "retentionSize '${RS}' vs volume '${VS}' — must be strictly smaller"
fi

# ------------------------------------------------------------- discovery
echo ""
echo "-- discovery --"
for m in backend worker frontend; do
    if [ "$APP_DEPLOYED" -eq 0 ]; then
        pending "ServiceMonitor/${m} in ${APP_NS}"
    else
        check "ServiceMonitor/${m} exists in ${APP_NS}" kubectl get servicemonitor "$m" -n "$APP_NS"
    fi
done
check "ServiceMonitor/jenkins exists in ${NAMESPACE}" kubectl get servicemonitor jenkins -n "$NAMESPACE"
check "the platform PrometheusRule exists" kubectl get prometheusrule platform-slo-and-alerts -n "$NAMESPACE"
# The setting without which every ServiceMonitor above is created, valid, and
# never looked at.
check "Prometheus selects monitors from every namespace" bash -c \
  "[ \"\$(kubectl get prometheus -n $NAMESPACE -o jsonpath='{.items[0].spec.serviceMonitorSelector}')\" = '{}' ] || \
   kubectl get prometheus -n $NAMESPACE -o yaml | grep -q 'serviceMonitorSelector: {}'"

# ------------------------------------------------------------- rbac
echo ""
echo "-- rbac --"
if kubectl get clusterrolebinding -o json 2>/dev/null \
     | python3 -c "
import json,sys
d=json.load(sys.stdin)
bad=[i['metadata']['name'] for i in d['items']
     if i['roleRef']['name']=='cluster-admin'
     and any(s.get('namespace')=='$NAMESPACE' for s in i.get('subjects') or [])]
sys.exit(1 if bad else 0)"; then
    ok "nothing in ${NAMESPACE} is bound to cluster-admin"
else
    bad "a ServiceAccount in ${NAMESPACE} is bound to cluster-admin"
fi
check "the Alertmanager ServiceAccount carries an IRSA role" bash -c \
  "kubectl get sa alertmanager -n $NAMESPACE -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' | grep -q '^arn:aws:iam::'"

# ------------------------------------------------------------- policy
echo ""
echo "-- network policy --"
check "default-deny is in place" kubectl get networkpolicy default-deny-all -n "$NAMESPACE"
for np in prometheus alertmanager grafana exporters; do
    check "NetworkPolicy/${np} exists" kubectl get networkpolicy "$np" -n "$NAMESPACE"
done
if [ "$APP_DEPLOYED" -eq 0 ]; then
    pending "the ${APP_NS} NetworkPolicy admitting scraping"
else
check "the app namespace admits scraping from ${NAMESPACE}" bash -c \
  "kubectl get networkpolicy backend -n $APP_NS -o yaml | grep -q '$NAMESPACE'"
fi
# Jenkins is installed by deploy.sh, not by the CD pipeline, so this one does
# not depend on the application being deployed.
check "Jenkins agents may reach ${NAMESPACE}" bash -c \
  "kubectl get networkpolicy jenkins-agents -n $JENKINS_NS -o yaml | grep -q '$NAMESPACE'"

# ------------------------------------------------------------- live targets
echo ""
echo "-- live scrape targets --"
# Needs the Prometheus API, which has no Ingress, so this uses a temporary
# port-forward. If it cannot be established the checks SKIP rather than pass:
# an unreachable Prometheus is not evidence of a healthy one.
PF_PID=""
if kubectl port-forward -n "$NAMESPACE" svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null 2>&1 & then
    PF_PID=$!
    sleep 4
fi
query() {
    curl -s --max-time 10 "http://localhost:19090/api/v1/query" --data-urlencode "query=$1" 2>/dev/null
}
if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null && [ -n "$(query 'up')" ]; then
    for job in backend worker frontend; do
        R=$(query "up{namespace=\"${APP_NS}\",service=\"${job}\"}")
        # Prometheus answers HTTP 200 with {"status":"error"} in the body, so
        # the status field is parsed rather than the exit code trusted, and an
        # EMPTY result is a failure -- no data is not proof of health.
        N=$(echo "$R" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(-1); raise SystemExit
print(len(d['data']['result']) if d.get('status')=='success' else -1)" 2>/dev/null || echo -1)
        if [ "${N:-0}" -gt 0 ]; then ok "target ${job} is being scraped (${N} instance(s))"
        elif [ "$APP_DEPLOYED" -eq 0 ]; then pending "target ${job}"
        else bad "target ${job} has no 'up' series"; fi
    done
    R=$(query 'app_build_info')
    N=$(echo "$R" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(len(d['data']['result']) if d.get('status')=='success' else 0)" 2>/dev/null || echo 0)
    if [ "${N:-0}" -gt 0 ]; then ok "app_build_info is reported by ${N} pod(s)"
    elif [ "$APP_DEPLOYED" -eq 0 ]; then pending "app_build_info"
    else bad "app_build_info is absent — the commit -> dashboard chain is broken"; fi

    # The Jenkins queue metric must exist under the single-prefix name.
    #
    # The plugin prefixes its metrics with the namespace configured in
    # jenkins/values.yaml, which very likely produces
    # `jenkins_jenkins_queue_size_value`; the ServiceMonitor's
    # metricRelabelings collapse that back to `jenkins_queue_size_value`, which
    # is what JenkinsQueueStuck and every panel in jenkins-delivery.json ask
    # for. This check exists so that a mistake in that reasoning is LOUD:
    # without it, a wrong prefix presents as an alert that never fires and a
    # dashboard of flat lines, which is indistinguishable from an idle Jenkins.
    #
    # The regex accepts either name so the failure message can say which one
    # arrived, rather than only that nothing did.
    R=$(query '{__name__=~"(jenkins_)?jenkins_queue_size_value"}')
    NAME=$(echo "$R" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
if d.get('status')=='success':
    for s in d['data']['result']:
        print(s['metric'].get('__name__','')); break" 2>/dev/null)
    if [ "$NAME" = "jenkins_queue_size_value" ]; then
        ok "Jenkins queue metric is present as ${NAME}"
    elif [ -n "$NAME" ]; then
        bad "the Jenkins queue metric arrived as ${NAME}, not jenkins_queue_size_value"
        echo "          the ServiceMonitor's metricRelabelings did not collapse the prefix;"
        echo "          JenkinsQueueStuck and every panel in jenkins-delivery.json are empty"
    else
        bad "no Jenkins queue metric under either name — JenkinsQueueStuck can never fire"
        echo "          check what the plugin actually emits:"
        echo "          kubectl exec -n ${JENKINS_NS} deploy/jenkins -- curl -s localhost:8080/prometheus | grep queue_size"
    fi
else
    skip "live target checks (could not reach the Prometheus API)"
    skip "app_build_info check (could not reach the Prometheus API)"
    skip "Jenkins queue metric name (could not reach the Prometheus API)"
fi
if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi

# ------------------------------------------------------------- result
echo ""
echo "=================================================="
echo "  ${PASS} passed, ${FAIL} failed, ${SKIP} skipped, ${PENDING} not deployed yet"
if [ "$FAIL" -gt 0 ]; then
    printf '  FAILED:  %s\n' "${FAILED[@]}"
fi
if [ "$PENDING" -gt 0 ]; then
    echo ""
    echo "  Not deployed yet — these belong to the application, which deploy.sh"
    echo "  does not deploy. The CD pipeline does. They are not failures and not"
    echo "  passes; they are unverified until a release has run:"
    printf '  PENDING: %s\n' "${NOT_DEPLOYED[@]}"
    echo ""
    echo "  Run application-ci in Jenkins, let it trigger application-cd, then"
    echo "  re-run this script. Everything above should then be checked for real."
fi
echo "=================================================="
# Exit on FAIL only. "Not deployed yet" must not fail a deploy that has not got
# to the deploying part -- but it is printed loudly enough that it cannot be
# mistaken for everything having been verified.
exit "$FAIL"
