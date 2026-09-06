#!/bin/bash
# scripts/port-forward-monitoring.sh
#
# Prometheus and Alertmanager have no Ingress, deliberately: neither has any
# authentication, so there is no login page to put behind an ALB. Exposing
# Prometheus would serve every metric to anyone who reached it -- including the
# AWS account ID embedded in ECR image labels, which
# scripts/collect-ci-evidence.sh strips out of the evidence pack on purpose --
# and would let a single expensive PromQL query OOM the monitoring plane.
#
# port-forward is proxied by the Kubernetes API server, so it is authenticated
# by your kubeconfig and authorised by RBAC. That is real authentication rather
# than an IP allowlist standing in for one.
#
# Grafana is the exception and has its own ALB: it has a login.
#
#   ./scripts/port-forward-monitoring.sh          # both, until Ctrl-C
set -euo pipefail

NAMESPACE="${NAMESPACE:-observability}"
PROM_PORT="${PROM_PORT:-9090}"
ALERT_PORT="${ALERT_PORT:-9093}"

# The Services the kube-prometheus-stack release creates. Resolved rather than
# hardcoded so a chart rename produces a clear error here instead of a hang.
# AUDIT FIX -- "I could not ask" was being reported as "it is not there".
#
# These two lookups used to end in `2>/dev/null || true`, so a kubectl that
# could not reach the cluster at all -- expired credentials, an operator IP no
# longer in the API allowlist, the wrong context -- produced an empty variable
# and the message "no Prometheus Service in namespace 'observability'. Is the
# stack installed?"
#
# That message sends you to reinstall a stack that is running perfectly well.
# It happened: Alertmanager was emailing alerts from inside the cluster while
# this script was advising a reinstall, because the operator's public IP had
# changed and the API server was refusing the connection.
#
# Same rule as report() in destroy.sh: a query that FAILED and a query that
# returned NOTHING are different answers and must never share a message.
# AUDIT FIX 2 -- THE SELECTOR MATCHED NOTHING, AND HAD NEVER MATCHED.
#
# These lookups used `-l app.kubernetes.io/name=prometheus`, copied from
# verify-observability.sh where it is correct. It is not correct here, because
# the two scripts look at objects built by DIFFERENT things:
#
#   StatefulSets, PVCs   built by the Prometheus OPERATOR, which sets
#                        app.kubernetes.io/name=prometheus     -> selector works
#   Services             built by the HELM CHART, which labels these two with
#                        the legacy `app=` key ONLY            -> selector fails
#
# Observed on chart 86.1.0, service kube-prometheus-stack-prometheus:
#   app=kube-prometheus-stack-prometheus, app.kubernetes.io/instance,
#   .../managed-by, .../part-of, .../version, chart, heritage, release,
#   self-monitor=true          -- and NO app.kubernetes.io/name at all.
#
# kubectl exits 0 when a selector matches nothing, so this produced an empty
# string, and the old code turned that into "no Prometheus Service in namespace
# observability. Is the stack installed?" -- advice to reinstall a stack that
# was serving, scraping and emailing alerts at that moment.
#
# Fixed with a fallback chain rather than one replacement selector, because
# label conventions here have already proven unstable across creators, and a
# single hardcoded key is what got us here. First match wins.
PROM_SELECTORS=(
    "app=kube-prometheus-stack-prometheus"   # the chart's Service, today
    "operated-prometheus=true"               # the operator's headless Service
    "app.kubernetes.io/name=prometheus"      # if a later chart adds the key
)
ALERT_SELECTORS=(
    "app=kube-prometheus-stack-alertmanager"
    "operated-alertmanager=true"
    "app.kubernetes.io/name=alertmanager"
)

kube_svc() { # kube_svc <selector>...
    local out rc sel
    for sel in "$@"; do
        out=$(kubectl get svc -n "$NAMESPACE" -l "$sel" \
              -o jsonpath='{.items[0].metadata.name}' 2>&1); rc=$?
        if [ "$rc" -ne 0 ]; then
            # "I could not ask" is not "it is not there". Same rule as
            # report() in destroy.sh: never let the two share a message.
            echo "ERROR: cannot query namespace '${NAMESPACE}' -- this says nothing" >&2
            echo "about whether the stack is installed, only that kubectl failed:" >&2
            echo "" >&2
            echo "  ${out}" >&2
            echo "" >&2
            echo "Usually the API allowlist. Compare your address with tfvars:" >&2
            echo "  curl -s https://checkip.amazonaws.com" >&2
            echo "  grep -A4 api_public_access_cidrs terraform/terraform.tfvars" >&2
            exit 2
        fi
        if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    done
    return 0   # asked successfully, nothing matched
}

PROM_SVC=$(kube_svc "${PROM_SELECTORS[@]}")
ALERT_SVC=$(kube_svc "${ALERT_SELECTORS[@]}")

if [ -z "$PROM_SVC" ]; then
    echo "ERROR: kubectl reached namespace '${NAMESPACE}' and none of these" >&2
    echo "selectors matched a Service:" >&2
    printf '  %s\n' "${PROM_SELECTORS[@]}" >&2
    echo "" >&2
    echo "What IS in the namespace:" >&2
    kubectl get svc -n "$NAMESPACE" --show-labels >&2 || true
    echo "" >&2
    echo "If the stack is genuinely absent:  ./scripts/install-observability.sh" >&2
    echo "If it is present, the chart's labels moved again -- add the new" >&2
    echo "selector to PROM_SELECTORS above." >&2
    exit 1
fi

cleanup() {
    # Kill the children, not the whole process group: killing the group would
    # also take the shell this was launched from when it is sourced.
    if [ -n "${PROM_PID:-}" ]; then kill "$PROM_PID" 2>/dev/null || true; fi
    if [ -n "${ALERT_PID:-}" ]; then kill "$ALERT_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

# AUDIT FIX 3 -- `kill -0` CANNOT TELL A LIVE PROCESS FROM A DEAD ONE.
#
# The previous guard was `kill -0 "$PROM_PID"`. A background child that exits
# becomes a ZOMBIE until the shell reaps it, and its PID stays in the process
# table, so `kill -0` returns success for a process that is already gone. The
# check passed on a dead forward every single time.
#
# Observed: with a forward already running on 9090/9093 from an earlier shell,
# both of this script's forwards died instantly with "address already in use",
# both `kill -0` checks passed, and the banner advertised two endpoints the
# script did not own. The comment on the old check said it existed so the
# script "cannot report an endpoint that does not answer". It could not tell.
#
# An earlier fix here noticed that only Prometheus was being checked and added
# the same check for Alertmanager -- duplicating a guard that never worked
# rather than asking whether it worked. The lesson is the one this project
# keeps relearning: test the guard, not just the thing it guards.
#
# So: ASK THE ENDPOINT. A port-forward is either answering HTTP or it is not,
# and that is a question with a real answer.
STDERR_DIR=$(mktemp -d)
kubectl port-forward -n "$NAMESPACE" "svc/${PROM_SVC}" "${PROM_PORT}:9090" \
    >/dev/null 2>"${STDERR_DIR}/prom" &
PROM_PID=$!

if [ -n "$ALERT_SVC" ]; then
    kubectl port-forward -n "$NAMESPACE" "svc/${ALERT_SVC}" "${ALERT_PORT}:9093" \
        >/dev/null 2>"${STDERR_DIR}/alert" &
    ALERT_PID=$!
fi

# Poll rather than sleep-and-hope. The old `sleep 2` was also a guess: on a
# slower link the tunnel is not up yet and the first curl gets connection
# refused, which is how an empty reply reached a JSON parser and produced a
# stack trace about "line 1 column 1".
endpoint_ready() { # endpoint_ready <port> <path>
    local _i
    for _i in $(seq 1 30); do
        if command -v curl >/dev/null 2>&1; then
            if curl -sS -o /dev/null --max-time 2 \
                 "http://localhost:${1}${2}" 2>/dev/null; then return 0; fi
        else
            # No curl: a TCP connect is weaker than an HTTP round trip, but it
            # is still an answer from the listener rather than a guess about a
            # PID. Said out loud rather than silently substituted.
            if (exec 3<>"/dev/tcp/127.0.0.1/${1}") 2>/dev/null; then
                exec 3>&- 2>/dev/null || true
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

if ! endpoint_ready "$PROM_PORT" "/-/ready"; then
    echo "ERROR: the Prometheus port-forward is not answering on ${PROM_PORT}." >&2
    if [ -s "${STDERR_DIR}/prom" ]; then
        echo "" >&2
        echo "kubectl said:" >&2
        sed 's/^/  /' "${STDERR_DIR}/prom" >&2
    fi
    echo "" >&2
    echo "If the port is in use, another port-forward is probably still running:" >&2
    echo "  ss -ltn | grep -E '${PROM_PORT}|${ALERT_PORT}'" >&2
    echo "  pkill -f 'kubectl port-forward'      # or reuse the one you have" >&2
    echo "Or pick different ports:  PROM_PORT=19090 ALERT_PORT=19093 $0" >&2
    rm -rf "$STDERR_DIR"
    exit 1
fi

# Alertmanager is not fatal -- Prometheus alone is useful -- but the URL is
# printed only if it actually answers.
if [ -n "${ALERT_PID:-}" ] && ! endpoint_ready "$ALERT_PORT" "/-/ready"; then
    echo "WARNING: the Alertmanager port-forward is not answering on ${ALERT_PORT}." >&2
    if [ -s "${STDERR_DIR}/alert" ]; then
        sed 's/^/  /' "${STDERR_DIR}/alert" >&2
    fi
    echo "         Prometheus is still available below." >&2
    ALERT_PID=""
fi
rm -rf "$STDERR_DIR"

echo "=================================================="
echo "  Prometheus    http://localhost:${PROM_PORT}"
echo "                  /targets   scrape health"
echo "                  /alerts    rule state"
echo "                  /graph     ad-hoc PromQL"
if [ -n "${ALERT_PID:-}" ]; then
echo "  Alertmanager  http://localhost:${ALERT_PORT}"
fi
echo ""
echo "  Ctrl-C to stop."
echo "=================================================="

wait
