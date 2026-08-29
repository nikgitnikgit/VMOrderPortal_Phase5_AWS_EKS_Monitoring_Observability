#!/bin/bash
# scripts/deploy.sh
#
# One command to go from nothing to a running Jenkins.
#
#   1. terraform apply           infrastructure (VPC, EKS, RDS, S3, SNS, ECR, IAM)
#   2. install-observability.sh  CRDs, Prometheus, Grafana, Alertmanager, rules
#   3. install-jenkins.sh        add-ons, namespaces, RBAC, TLS, agent image, Jenkins
#   4. create-jobs.sh            the two jobs, from jenkins/jobs/seed.groovy
#   5. register-webhook.sh       push-to-main triggers CI (skipped without a token)
#   6. verify-jenkins.sh         assert the result matches the design
#   7. verify-observability.sh   assert the monitoring plane matches the design
#
# Step 2 comes BEFORE step 3 on purpose: the Jenkins and application charts
# ship ServiceMonitor objects, and a chart that references a CRD which does not
# exist yet fails outright with "no matches for kind ServiceMonitor".
#
# The APPLICATION is deployed by the Jenkins CD pipeline, not by this script.
# That separation is the point of phase 4.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=================================================="
echo "  VM Order Portal — deploy"
echo "=================================================="

echo ""
echo "STEP 1/7: terraform apply (EKS takes 15-20 minutes — this is normal)"
cd "$REPO_ROOT/terraform"
terraform init -input=false
terraform apply -auto-approve

echo ""
echo "STEP 2/7: installing the observability stack"
cd "$REPO_ROOT"
./scripts/install-observability.sh

echo ""
echo "STEP 3/7: installing Jenkins"
./scripts/install-jenkins.sh

echo ""
echo "STEP 4/7: creating jobs from code"
./scripts/create-jobs.sh

echo ""
echo "STEP 5/7: registering the GitHub webhook"
# The result is captured rather than allowed to abort the run. deploy.sh is
# `set -e`, and register-webhook.sh exits non-zero when GitHub cannot reach the
# ALB -- which it should, since a silent webhook failure is what sent CI onto
# the 5-minute poll unnoticed. But the cluster and Jenkins are already up and
# correct at this point, and aborting here skipped step 5 entirely, so the
# operator lost verify-jenkins.sh over a notification path. Report it at the
# end instead, loudly, and still verify.
WEBHOOK_STATUS="ok"
if [ -n "${GITHUB_TOKEN:-}" ] || [ -f "$HOME/.github_token" ]; then
    ./scripts/register-webhook.sh || WEBHOOK_STATUS="failed"
else
    WEBHOOK_STATUS="skipped"
    echo "  SKIPPED — no GitHub token found."
    echo "  CI will still run on a 5-minute SCM poll."
    echo "  For push-triggered builds:"
    echo "    export GITHUB_TOKEN=ghp_xxx && ./scripts/register-webhook.sh"
fi

echo ""
echo "STEP 6-7/7: verifying"
# SKIP_VERIFY exists for the offline mock test suite: verify-jenkins.sh
# inspects a live cluster (RBAC decisions, running pods) and cannot be
# satisfied by mocked binaries.
if [ "${SKIP_VERIFY:-0}" = "1" ]; then
    echo "  SKIPPED (SKIP_VERIFY=1)"
else
    ./scripts/verify-jenkins.sh
    ./scripts/verify-observability.sh
fi

echo ""
if [ "$WEBHOOK_STATUS" != "ok" ]; then
    echo "=================================================="
    echo "  WEBHOOK NOT CONFIRMED (${WEBHOOK_STATUS})"
    echo ""
    echo "  Everything else deployed. CI will still build, but only via the"
    echo "  5-minute poll, and no build will be attributable to a push."
    echo ""
    echo "  Re-run once the ALB is serving:"
    echo "    export GITHUB_TOKEN=ghp_xxx && ./scripts/register-webhook.sh"
    echo "=================================================="
    echo ""
fi

# ---------------------------------------------------------------- handover
#
# EVERYTHING NEEDED TO LOG IN, IN ONE PLACE, WITH NO FOLLOW-UP COMMANDS.
#
# This used to end with "Grafana's URL and password were printed in step 2",
# which was wrong twice: step 2 runs before the load balancer controller
# exists, so the URL it printed was the literal string "<pending>"; and a
# credential five hundred lines up a scrollback is a credential you go hunting
# for. Both are read live from the cluster here, at the one moment when
# everything that produces them has finished.
if [ "${SKIP_VERIFY:-0}" != "1" ]; then
    echo ""
    echo "  collecting URLs and credentials..."

    # Grafana's ALB is created by the controller that install-jenkins.sh
    # installed a few minutes ago, so unlike in step 2 there is now something
    # to wait for. Bounded, and its absence is reported rather than printed as
    # a URL.
    GRAFANA_HOST=""
    for _ in $(seq 1 30); do
        GRAFANA_HOST=$(kubectl get ingress -n observability -l app.kubernetes.io/name=grafana \
            -o jsonpath="{.items[0].status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)
        [ -n "$GRAFANA_HOST" ] && break
        sleep 10
    done
    JENKINS_HOST=$(kubectl get ingress jenkins -n jenkins \
        -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)

    JENKINS_PASS=$(kubectl get secret jenkins -n jenkins \
        -o jsonpath="{.data.jenkins-admin-password}" 2>/dev/null | base64 -d || true)
    GRAFANA_PASS=$(kubectl get secret grafana-admin -n observability \
        -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d || true)

    echo ""
    echo "=================================================="
    echo "  READY"
    echo "=================================================="
    echo ""
    if [ -n "$JENKINS_HOST" ]; then
        echo "  Jenkins   https://${JENKINS_HOST}"
    else
        echo "  Jenkins   ALB not ready yet — kubectl get ingress jenkins -n jenkins"
    fi
    echo "            admin / ${JENKINS_PASS:-<could not read secret jenkins/jenkins>}"
    echo ""
    if [ -n "$GRAFANA_HOST" ]; then
        echo "  Grafana   https://${GRAFANA_HOST}"
    else
        echo "  Grafana   ALB not ready after 5 minutes —"
        echo "            kubectl get ingress -n observability -l app.kubernetes.io/name=grafana"
    fi
    echo "            admin / ${GRAFANA_PASS:-<could not read secret grafana-admin>}"
    echo ""
    echo "  Both are restricted to your IP, and both certificates are"
    echo "  self-signed, so the browser warns once."
    echo ""
    echo "  Prometheus and Alertmanager have NO Ingress, deliberately:"
    echo "    ./scripts/port-forward-monitoring.sh"
    echo ""
    echo "  The APPLICATION is not deployed yet — deploy.sh does not deploy it."
    echo "  Run application-ci in Jenkins; it hands off to application-cd, which"
    echo "  prints the application URL when the release passes its checks."
    echo "=================================================="
else
    echo "=================================================="
    echo "Infrastructure and Jenkins are ready (verification skipped)."
    echo "=================================================="
fi
