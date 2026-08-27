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
PROM_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
ALERT_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$PROM_SVC" ]; then
    echo "ERROR: no Prometheus Service in namespace '${NAMESPACE}'." >&2
    echo "Is the stack installed?  ./scripts/install-observability.sh" >&2
    exit 1
fi

cleanup() {
    # Kill the children, not the whole process group: killing the group would
    # also take the shell this was launched from when it is sourced.
    if [ -n "${PROM_PID:-}" ]; then kill "$PROM_PID" 2>/dev/null || true; fi
    if [ -n "${ALERT_PID:-}" ]; then kill "$ALERT_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

kubectl port-forward -n "$NAMESPACE" "svc/${PROM_SVC}" "${PROM_PORT}:9090" >/dev/null &
PROM_PID=$!

if [ -n "$ALERT_SVC" ]; then
    kubectl port-forward -n "$NAMESPACE" "svc/${ALERT_SVC}" "${ALERT_PORT}:9093" >/dev/null &
    ALERT_PID=$!
fi

sleep 2

# Confirm it actually came up rather than printing a URL that does not answer.
# A port-forward that fails to bind exits immediately and would otherwise leave
# this script cheerfully reporting two working endpoints.
if ! kill -0 "$PROM_PID" 2>/dev/null; then
    echo "ERROR: the Prometheus port-forward exited immediately." >&2
    echo "Usually port ${PROM_PORT} is already in use." >&2
    exit 1
fi
# AUDIT FIX -- the Alertmanager forward was never checked, only Prometheus's.
#
# The comment above says this exists so the script cannot report an endpoint
# that does not answer, and then the URL printed below was gated on $ALERT_SVC
# -- a string set before the fork, which is true whether or not the forward
# survived. Port 9093 already in use meant the forward died instantly and the
# script still advertised http://localhost:9093, which is precisely the failure
# it was written to prevent, one variable to the left.
if [ -n "${ALERT_PID:-}" ] && ! kill -0 "$ALERT_PID" 2>/dev/null; then
    echo "WARNING: the Alertmanager port-forward exited immediately;" >&2
    echo "         port ${ALERT_PORT} is probably already in use." >&2
    echo "         Prometheus is still available below." >&2
    ALERT_PID=""
fi

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
