#!/bin/bash
# scripts/validate-observability.sh — CI validation of the observability objects.
#
# Run by Jenkinsfile-ci's Validate stage. Static only: it renders, parses and
# schema-checks. It NEVER talks to a cluster and never applies anything, which
# is the CI/CD separation the assignment requires — CI validates the monitoring
# objects, CD is the only thing that deploys them.
#
# Four checks, and each one exists because of a specific way an observability
# change fails silently:
#
#   1. PromQL that does not parse. A PrometheusRule with a syntax error is
#      accepted by the API server -- the CRD schema only knows `expr` is a
#      string -- and then fails at EVALUATION time, inside Prometheus, where
#      the only symptom is an alert that never fires.
#
#   2. A manifest that is not a valid object. Same shape: `kubectl apply`
#      accepts a ServiceMonitor with a misspelled field and the operator
#      quietly ignores it.
#
#   3. A dashboard panel whose query does not parse, or which points at a
#      datasource uid that does not exist. Grafana renders it as an empty
#      panel, which looks exactly like "no traffic".
#
#   4. A metric name that nothing produces. The single most common way a
#      dashboard is wrong: a typo in a metric name gives a panel that is empty
#      forever and never errors.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
step() { echo ""; echo "--- $1 ---"; }
ok()   { echo "  [ OK ]  $1"; }
bad()  { echo "  [FAIL]  $1"; FAIL=1; }

need() {
    command -v "$1" >/dev/null 2>&1 && return 0
    # A missing tool must NOT pass silently. In CI the agent image carries all
    # of them; anywhere else, say so loudly and fail rather than skipping.
    bad "$1 is not installed — this check cannot run, so it does not pass"
    return 1
}

echo "=================================================="
echo "  Validating observability objects (static)"
echo "=================================================="

# ---------------------------------------------------------------- render
step "rendering charts"
for c in backend worker frontend; do
    helm template "$c" "helm/$c" \
        --set image.registry=dummy.ecr.aws \
        --set serviceAccount.roleArn=arn:aws:iam::000000000000:role/dummy \
        > "$WORK/app-$c.yaml"
    ok "helm/$c renders"
done
helm template observability helm/observability > "$WORK/observability.yaml"
ok "helm/observability renders"

# ------------------------------------------------------------- 1. promtool
step "1/4  PromQL in every PrometheusRule"
# Extracted with python3, NOT with yq.
#
# There are two unrelated programs called yq -- mikefarah's Go one and
# kislyuk's Python jq wrapper -- with incompatible syntax. Whichever this
# script assumed, it would produce EMPTY output on a machine with the other
# one, and an empty rules file passes promtool trivially. python3 is already a
# hard dependency of the test suite and the agent image, so this removes the
# ambiguity rather than betting on it.
#
# The "zero rules found" guard below stays regardless: it is what caught this.
if need promtool; then
    RULE_COUNT=0
    for f in "$WORK"/*.yaml; do
        python3 - "$f" > "$WORK/rules-$(basename "$f")" <<'PYEOF' || true
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
specs = [d["spec"] for d in docs if d.get("kind") == "PrometheusRule"]
if specs:
    merged = {"groups": [g for s in specs for g in s.get("groups", [])]}
    print(yaml.safe_dump(merged, default_flow_style=False))
PYEOF
        # AUDIT FIX 1 -- `grep -q 'groups:'` is satisfied by `groups: []`.
        #
        # A PrometheusRule that renders with an EMPTY groups list produced a
        # file that passed this gate, promtool exited 0 on it, RULE_COUNT was
        # incremented, and the OK line literally printed "0 rules found" while
        # the step reported success. Counting FILES was never the point;
        # counting rules is.
        if [ -s "$WORK/rules-$(basename "$f")" ] && grep -qE '^- (alert|record):|^  - (alert|record):|^    - (alert|record):' "$WORK/rules-$(basename "$f")"; then
            if promtool check rules "$WORK/rules-$(basename "$f")" > "$WORK/promtool.out" 2>&1; then
                # AUDIT FIX 2 -- `N=$(grep ... | head -1)` under `set -e` with
                # `pipefail` ABORTS THE SCRIPT when promtool's wording changes
                # and grep finds nothing. Validation then stopped here, before
                # kubeconform, the dashboards and the metric contract ever ran,
                # and surfaced as a bare exit 1 indistinguishable from a real
                # validation failure. `|| true` makes a cosmetic label
                # cosmetic.
                N=$(grep -oE '[0-9]+ rules found' "$WORK/promtool.out" | head -1 || true)
                RULES_IN_FILE=$(printf '%s' "${N:-0}" | grep -oE '^[0-9]+' || true)
                if [ "${RULES_IN_FILE:-0}" -eq 0 ]; then
                    bad "$(basename "$f"): promtool validated 0 rules — nothing was actually checked"
                    continue
                fi
                ok "$(basename "$f"): ${N:-rules valid}"
                RULE_COUNT=$((RULE_COUNT + 1))
            else
                bad "$(basename "$f"): $(head -5 "$WORK/promtool.out" | tr '\n' ' ')"
            fi
        fi
    done
    # Zero rule files found is itself a failure: it means the render produced
    # nothing to check, and a check that checks nothing is the false-success
    # shape this repository keeps finding.
    if [ "$RULE_COUNT" -eq 0 ]; then
        bad "no PrometheusRule was found in any rendered chart — nothing was actually validated"
    fi
fi

# ---------------------------------------------------------- 2. kubeconform
step "2/4  Kubernetes schema, including custom resources"
if need kubeconform; then
    # Vendored CRD schemas: validation must not depend on reaching the internet
    # from a build agent, and a schema fetched at build time is a schema that
    # can change under a build that is otherwise reproducible.
    if kubeconform \
            -strict \
            -ignore-missing-schemas=false \
            -schema-location default \
            -schema-location "tests/crd-schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
            -summary \
            "$WORK"/app-*.yaml "$WORK/observability.yaml" > "$WORK/kc.out" 2>&1; then
        ok "$(tail -1 "$WORK/kc.out")"
    else
        bad "schema validation failed:"
        sed 's/^/          /' "$WORK/kc.out" | head -15
    fi
fi

# ----------------------------------------------------------- 3+4. dashboards
step "3/4  dashboard JSON, datasource and PromQL"
python3 tests/check_dashboards.py || FAIL=1

step "4/4  every referenced metric is one something produces"
python3 tests/check_metrics_contract.py || FAIL=1

echo ""
echo "=================================================="
if [ "$FAIL" -ne 0 ]; then
    echo "  VALIDATION FAILED"
    echo "=================================================="
    exit 1
fi
echo "  All observability objects valid"
echo "=================================================="
