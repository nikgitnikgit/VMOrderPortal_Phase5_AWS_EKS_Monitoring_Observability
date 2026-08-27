#!/bin/bash
# scripts/monitoring-gate.sh — the post-deploy monitoring gate.
#
# Run by Jenkinsfile-cd after the rollout and the smoke test. Asks Prometheus
# four questions about the release that was just deployed, and exits non-zero
# if any of them is answered badly. A non-zero exit hands over to the CD
# pipeline's post{failure} block: diagnostics, helm rollback, SNS.
#
# It lives in a script rather than inside the Jenkinsfile so it can be read,
# linted and unit-tested. A 120-line shell block inside a Groovy string is none
# of those three.
#
# (A comment line here must never BEGIN with the linter's own name: it is then
# read as a directive, and the whole file fails to parse with SC1073. Which is
# the same shape as the phase 4 grep that matched the comment explaining the
# very pattern it was hunting for -- a check tripping over its own
# documentation. Keep the tool's name mid-sentence, as it is here.)
#
#   ./scripts/monitoring-gate.sh <git_sha> [namespace]
#
# THREE WAYS THIS GATE COULD QUIETLY BECOME DECORATION
#
# Every one of them has happened in this project before, in a different check,
# and every one gets an explicit branch here:
#
#   1. NO DATA IS NOT HEALTH. An empty result vector means Prometheus has
#      nothing to say about the thing being asked. That is a failure, not a
#      pass. A gate that treats "I don't know" as "fine" is worse than no gate,
#      because it produces a green tick.
#
#   2. PROMETHEUS ANSWERS 200 ON A FAILED QUERY. The body carries
#      {"status":"error"}. `curl -f` only trips on >= 400, so it sees success.
#      The status field is parsed, always.
#
#   3. A RETRY LOOP THAT RUNS OUT MUST FAIL. In phase 4 the ALB smoke probe
#      exhausted its retries, the loop simply ended, and ending was success.
#      Here the loop sets a flag and the flag is checked afterwards.
set -uo pipefail

GIT_SHA="${1:-}"
NAMESPACE="${2:-devops-app}"

PROM_URL="${PROM_URL:-http://kube-prometheus-stack-prometheus.observability.svc:9090}"
WINDOW="${WINDOW:-3m}"
MAX_ERROR_RATIO="${MAX_ERROR_RATIO:-0.02}"
MAX_P95_SECONDS="${MAX_P95_SECONDS:-0.5}"
EXPECTED_TARGETS="${EXPECTED_TARGETS:-3}"
# A fresh deployment has no data for the first minute or so: pods have to start,
# be scraped at least twice for a rate() to exist, and register. Bounded, and
# the bound is enforced below.
ATTEMPTS="${ATTEMPTS:-20}"
SLEEP_SECONDS="${SLEEP_SECONDS:-15}"

if [ -z "$GIT_SHA" ]; then
    echo "usage: $0 <git_sha> [namespace]" >&2
    exit 2
fi

FAILURES=0
note()  { echo "    $1"; }
pass()  { echo "  [ OK ]  $1"; }
fail()  { echo "  [FAIL]  $1"; FAILURES=$((FAILURES+1)); }

# query <promql>  ->  prints the scalar value of the first result, or nothing.
# Prints NOTHING on: a transport error, a non-success status, or an empty
# result. The caller must treat "nothing" as failure -- see reason 1 above.
query() {
    local q="$1" body
    body=$(curl -s --max-time 15 -G "${PROM_URL}/api/v1/query" \
                --data-urlencode "query=${q}" 2>/dev/null) || return 1
    printf '%s' "$body" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(1)                       # not JSON at all: a proxy error page
if d.get("status") != "success":      # HTTP 200 with an error body
    sys.exit(1)
res = d.get("data", {}).get("result") or []
if not res:
    sys.exit(1)                       # empty vector: no data, not health
print(res[0]["value"][1])
' 2>/dev/null
}

echo "=================================================="
echo "  MONITORING GATE"
echo "  namespace : ${NAMESPACE}"
echo "  commit    : ${GIT_SHA}"
echo "  window    : ${WINDOW}"
echo "  prometheus: ${PROM_URL}"
echo "=================================================="

# ---------------------------------------------------------------------------
# 0. Prometheus must be reachable at all.
# ---------------------------------------------------------------------------
REACHABLE=0
for i in $(seq 1 5); do
    if [ -n "$(query 'vector(1)')" ]; then REACHABLE=1; break; fi
    note "Prometheus not answering yet (${i}/5)"
    sleep 5
done
if [ "$REACHABLE" -ne 1 ]; then
    echo ""
    echo "  [FAIL]  Prometheus is unreachable at ${PROM_URL}"
    echo "          The gate cannot verify this release, so it does not pass it."
    echo "          Check: the observability namespace is up, and the"
    echo "          jenkins-agents NetworkPolicy allows egress to it on 9090."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Every application target is up, and there are as many as we deployed.
# ---------------------------------------------------------------------------
echo ""
echo "-- 1/4  scrape targets --"
TARGETS_OK=0
for i in $(seq 1 "$ATTEMPTS"); do
    N=$(query "count(up{namespace=\"${NAMESPACE}\"} == 1)")
    if [ -n "$N" ] && [ "${N%%.*}" -ge "$EXPECTED_TARGETS" ]; then
        pass "${N%%.*} application targets up (expected at least ${EXPECTED_TARGETS})"
        TARGETS_OK=1
        break
    fi
    note "targets up: ${N:-none yet} — waiting (${i}/${ATTEMPTS})"
    sleep "$SLEEP_SECONDS"
done
# Reason 3: the loop ending is not success.
if [ "$TARGETS_OK" -ne 1 ]; then
    fail "fewer than ${EXPECTED_TARGETS} targets are up after $((ATTEMPTS * SLEEP_SECONDS))s"
fi

# ---------------------------------------------------------------------------
# 2. The pods now serving traffic report THIS commit.
#
# This is the proof chain, enforced rather than asserted: commit -> CI build ->
# image digest -> Pod -> metric. If app_build_info does not carry this git_sha,
# something older is still serving and the deploy did not take effect, however
# green the rollout looked.
# ---------------------------------------------------------------------------
echo ""
echo "-- 2/4  the running build is the one we deployed --"
BUILD_OK=0
for i in $(seq 1 "$ATTEMPTS"); do
    N=$(query "count(app_build_info{namespace=\"${NAMESPACE}\",git_sha=\"${GIT_SHA}\"} == 1)")
    if [ -n "$N" ] && [ "${N%%.*}" -ge 1 ]; then
        pass "${N%%.*} pod(s) report git_sha=${GIT_SHA}"
        BUILD_OK=1
        break
    fi
    note "no pod reporting ${GIT_SHA} yet (${i}/${ATTEMPTS})"
    sleep "$SLEEP_SECONDS"
done
if [ "$BUILD_OK" -ne 1 ]; then
    fail "no pod reports app_build_info{git_sha=\"${GIT_SHA}\"}"
    note "the rollout may have succeeded while an older image kept serving,"
    note "or GIT_SHA was not passed into the chart"
fi

# ---------------------------------------------------------------------------
# 3. Error ratio within the SLO burn threshold.
# ---------------------------------------------------------------------------
echo ""
echo "-- 3/4  error ratio --"
ERR=$(query "(sum(rate(http_requests_total{namespace=\"${NAMESPACE}\",status=\"5xx\"}[${WINDOW}])) / sum(rate(http_requests_total{namespace=\"${NAMESPACE}\"}[${WINDOW}]))) or vector(0)")
if [ -z "$ERR" ]; then
    # `or vector(0)` means an answer exists even with zero traffic, so an empty
    # result here is not "no traffic" -- it is a broken query or a Prometheus
    # that stopped answering mid-gate.
    fail "the error-ratio query returned no data at all"
else
    if python3 -c "import sys; sys.exit(0 if float('${ERR}') <= float('${MAX_ERROR_RATIO}') else 1)"; then
        pass "5xx ratio ${ERR} is within ${MAX_ERROR_RATIO}"
    else
        fail "5xx ratio ${ERR} exceeds ${MAX_ERROR_RATIO}"
    fi
fi

# ---------------------------------------------------------------------------
# 4. p95 latency within the SLO.
# ---------------------------------------------------------------------------
echo ""
echo "-- 4/4  p95 latency --"
P95=$(query "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace=\"${NAMESPACE}\"}[${WINDOW}])))")
if [ -z "$P95" ]; then
    # No histogram data means no requests were observed in the window. After a
    # smoke test has just run, that means the metrics path is broken -- which
    # is exactly the kind of silence this gate exists to refuse.
    fail "no latency data in the last ${WINDOW} — the smoke test should have produced some"
elif [ "$P95" = "NaN" ]; then
    fail "p95 is NaN — the histogram has no observations in the window"
else
    if python3 -c "import sys; sys.exit(0 if float('${P95}') <= float('${MAX_P95_SECONDS}') else 1)"; then
        pass "p95 ${P95}s is within ${MAX_P95_SECONDS}s"
    else
        fail "p95 ${P95}s exceeds ${MAX_P95_SECONDS}s"
    fi
fi

echo ""
echo "=================================================="
if [ "$FAILURES" -gt 0 ]; then
    echo "  GATE FAILED (${FAILURES} check(s))"
    echo ""
    echo "  This release is NOT considered healthy. The pipeline will roll back."
    echo "  Runbook: docs/runbooks/MonitoringGateFailed.md"
    echo "=================================================="
    exit 1
fi
echo "  GATE PASSED — the release is serving and within SLO"
echo "=================================================="
