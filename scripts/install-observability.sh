#!/bin/bash
# scripts/install-observability.sh
#
# Installs the monitoring plane. Idempotent: safe to re-run.
#
# Runs AFTER `terraform apply` and BEFORE install-jenkins.sh. The ordering is
# load bearing: the application and Jenkins charts ship ServiceMonitor objects,
# and a ServiceMonitor is a custom resource. Install those charts first and
# Helm fails with "no matches for kind ServiceMonitor" on a cluster where the
# CRD does not exist yet.
#
# Reads every environment-specific value from Terraform outputs, exactly like
# install-jenkins.sh, so nothing is hard-coded and a second contributor gets
# their own account's values automatically.
#
# Division of labour, unchanged from phase 4:
#   Terraform  = infrastructure
#   Bootstrap  = platform (this script, then install-jenkins.sh)
#   Jenkins    = the application
# CD may READ Prometheus. It must not be able to reconfigure it, which is why
# this is a bootstrap script and not a pipeline stage.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/terraform"

# ---------------------------------------------------------------- outputs
CLUSTER_NAME=$(terraform output -raw cluster_name)
AWS_REGION=$(terraform output -raw aws_region)
VPC_CIDR=$(terraform output -raw vpc_cidr)
SNS_TOPIC_ARN=$(terraform output -raw sns_topic_arn)
ALERTMANAGER_ROLE_ARN=$(terraform output -raw alertmanager_role_arn)
MONITORING_NODE_GROUP=$(terraform output -raw monitoring_node_group)
NAMESPACE=$(terraform output -raw observability_namespace)

CHART_VERSION=$(tr -d '[:space:]' < "$REPO_ROOT/helm/observability/CHART_VERSION")

cd "$REPO_ROOT"

echo "=================================================="
echo "  Installing observability on ${CLUSTER_NAME}"
echo "  kube-prometheus-stack: ${CHART_VERSION}"
echo "  namespace:             ${NAMESPACE}"
echo "  node group:            ${MONITORING_NODE_GROUP}"
echo "=================================================="

# ------------------------------------------------------- 1. connect kubectl
echo ""
echo "[1/7] Connecting kubectl..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
kubectl get nodes

# --------------------------------------------- 2. namespace + storage class
echo ""
echo "[2/7] Namespace and StorageClass..."
kubectl apply -f "$REPO_ROOT/k8s/namespace.yaml"
kubectl apply -f "$REPO_ROOT/k8s/storageclass-gp3.yaml"

# ------------------------------------------------------------------ 3. CRDs
echo ""
echo "[3/7] Prometheus Operator CRDs (server-side)..."
#
# THIS STEP EXISTS BECAUSE HELM CANNOT DO IT.
#
# Two facts, both of which bite on the first UPGRADE rather than the install:
#
#   1. Helm installs the CRDs in a chart's crds/ directory exactly once and
#      never upgrades them. A later chart version whose values reference a new
#      CRD field then fails with a schema error that reads like a values error.
#      crds.enabled=false in our values tells the chart not to try.
#
#   2. These CRDs are enormous (the Prometheus CRD alone is ~1MB). A
#      client-side `kubectl apply` stores the whole object in the
#      last-applied-configuration ANNOTATION, and annotations are capped at
#      262144 bytes. It fails with "metadata.annotations: Too long".
#      --server-side keeps the merge on the API server and has no such limit.
#
# --force-conflicts: on a re-run the fields are already owned by this same
# applier, and without it every re-run stops on a conflict.
CRD_BASE="https://raw.githubusercontent.com/prometheus-community/helm-charts/kube-prometheus-stack-${CHART_VERSION}/charts/kube-prometheus-stack/charts/crds/crds"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents \
           prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
    echo "  ${crd}"
    kubectl apply --server-side --force-conflicts \
        -f "${CRD_BASE}/crd-${crd}.yaml" >/dev/null
done

echo "  waiting for the API server to serve the new kinds..."
kubectl wait --for condition=established --timeout=120s \
    crd/servicemonitors.monitoring.coreos.com \
    crd/prometheusrules.monitoring.coreos.com >/dev/null

# ----------------------------------------------------- 4. Grafana admin user
echo ""
echo "[4/7] Grafana admin credentials..."
# Generated here, printed once, never committed. The same reasoning as the
# Jenkins admin password: a password in Git is a password that has leaked.
#
# Only created if absent, so re-running this script does not silently change
# the password out from under a browser session that is already logged in.
if kubectl get secret grafana-admin -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "  already exists — leaving it alone"
    GRAFANA_PASS=""
else
    GRAFANA_PASS=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    kubectl create secret generic grafana-admin \
        --namespace "$NAMESPACE" \
        --from-literal=admin-user=admin \
        --from-literal=admin-password="$GRAFANA_PASS"
    echo "  created"
fi

# ------------------------------------------------------ 5. TLS + operator IP
echo ""
echo "[5/7] Grafana certificate and access restriction..."
GRAFANA_CERT_ARN=$("$REPO_ROOT/scripts/create-cert.sh" --purpose grafana)
echo "  certificate: ${GRAFANA_CERT_ARN}"

# The same trap as the EKS API allowlist: when your ISP rotates your address
# the ALB starts dropping (not refusing) your packets, and the browser hangs
# rather than erroring. Resolved fresh on every run so a re-run is the fix.
# AUDIT FIX -- the escape hatch this error message documents was unreachable.
#
# The lookup ran first and `exit 1` came BEFORE OPERATOR_CIDRS was consulted,
# so `OPERATOR_CIDRS=1.2.3.4/32 ./scripts/install-observability.sh` -- the exact
# command the error printed -- still failed with that same error. Behind a
# corporate proxy, on a host with no egress to checkip, or when the service is
# simply down, there was no way to install at all.
#
# An explicitly supplied value is now honoured without the lookup, which is
# also the faster path.
if [ -n "${OPERATOR_CIDRS:-}" ]; then
    echo "  using OPERATOR_CIDRS from the environment"
else
    OPERATOR_IP=$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
    if ! echo "$OPERATOR_IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        echo "ERROR: could not determine your public IP (got '${OPERATOR_IP}')." >&2
        echo "Set it by hand: OPERATOR_CIDRS=1.2.3.4/32 $0" >&2
        exit 1
    fi
    OPERATOR_CIDRS="${OPERATOR_IP}/32"
fi
echo "  Grafana will be reachable from: ${OPERATOR_CIDRS}"

# --------------------------------------------------- 6. the upstream chart
echo ""
echo "[6/7] Installing kube-prometheus-stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update >/dev/null

# Fail with a useful message rather than a 404 from the repository.
if ! helm search repo prometheus-community/kube-prometheus-stack \
        --version "$CHART_VERSION" 2>/dev/null | grep -q "$CHART_VERSION"; then
    echo "ERROR: chart version '${CHART_VERSION}' not found." >&2
    echo "Pick a current one and write it to helm/observability/CHART_VERSION:" >&2
    helm search repo prometheus-community/kube-prometheus-stack --versions 2>/dev/null | head -6 >&2
    exit 1
fi

# The values file is committed; only the environment-specific placeholders are
# substituted here. Rendered to a temp file rather than edited in place, so the
# repository copy is never modified by a deploy -- a working tree that changes
# when you deploy is a working tree that eventually gets committed by accident.
RENDERED=$(mktemp)
trap 'rm -f "$RENDERED"' EXIT
sed -e "s|PLACEHOLDER_MONITORING_NODEGROUP|${MONITORING_NODE_GROUP}|g" \
    -e "s|PLACEHOLDER_ALERTMANAGER_ROLE_ARN|${ALERTMANAGER_ROLE_ARN}|g" \
    -e "s|PLACEHOLDER_SNS_TOPIC_ARN|${SNS_TOPIC_ARN}|g" \
    -e "s|PLACEHOLDER_AWS_REGION|${AWS_REGION}|g" \
    -e "s|PLACEHOLDER_OPERATOR_CIDRS|${OPERATOR_CIDRS}|g" \
    -e "s|PLACEHOLDER_GRAFANA_CERT_ARN|${GRAFANA_CERT_ARN}|g" \
    "$REPO_ROOT/helm/observability/kube-prometheus-stack.values.yaml" > "$RENDERED"

# Refuse to install a values file that still contains a placeholder. Every one
# of them fails in a different quiet way if it reaches the cluster: an unsolved
# node group means Pending pods, an unsolved role ARN means Alertmanager
# publishes nothing and says nothing.
if grep -q "PLACEHOLDER_" "$RENDERED"; then
    echo "ERROR: unsubstituted placeholders remain:" >&2
    grep -n "PLACEHOLDER_" "$RENDERED" >&2
    exit 1
fi

helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION" \
    -f "$RENDERED" \
    --wait --timeout 15m

# ------------------------------------------- 7. our own dashboards and rules
echo ""
echo "[7/7] Dashboards, platform rules and NetworkPolicies..."
helm upgrade --install observability "$REPO_ROOT/helm/observability" \
    --namespace "$NAMESPACE" \
    --set namespace="$NAMESPACE" \
    --set vpcCidr="$VPC_CIDR" \
    --wait --timeout 5m

echo ""
echo "  waiting for Grafana's ALB..."
GRAFANA_HOST=""
for i in $(seq 1 36); do
    # By NAME, not .items[0]. AUDIT FIX: the sidecar's dashboards, a future
    # per-service Ingress, or anything else in this namespace could occupy
    # index 0, and the script would then print someone else's ALB hostname as
    # the Grafana URL. install-jenkins.sh already does this correctly with
    # `get ingress jenkins`.
    GRAFANA_HOST=$(kubectl get ingress -n "$NAMESPACE" \
        -l app.kubernetes.io/name=grafana \
        -o jsonpath="{.items[0].status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)
    [ -n "$GRAFANA_HOST" ] && break
    echo "    ... not ready yet ($i/36)"
    sleep 10
done

echo ""
echo "=================================================="
echo "Observability installed."
echo ""
echo "  Grafana:  https://${GRAFANA_HOST:-<pending>}"
echo "  User:     admin"
if [ -n "$GRAFANA_PASS" ]; then
echo "  Password: ${GRAFANA_PASS}"
echo "            ^ shown ONCE. Store it now."
else
echo "  Password: unchanged (secret already existed)"
echo "            kubectl get secret grafana-admin -n ${NAMESPACE} \\"
echo "              -o jsonpath='{.data.admin-password}' | base64 -d"
fi
echo ""
echo "  The certificate is self-signed, so the browser warns once."
echo "  Access is restricted to ${OPERATOR_CIDRS}."
echo ""
echo "  Prometheus and Alertmanager have NO Ingress, deliberately - neither has"
echo "  any authentication of its own. Reach them with:"
echo "    ./scripts/port-forward-monitoring.sh"
echo ""
echo "Next:  ./scripts/install-jenkins.sh"
echo "       ./scripts/verify-observability.sh"
echo "=================================================="
