#!/bin/bash
# scripts/destroy.sh
# Teardown — hardened by real live runs.
# Added vs phase 3:
#   - Uninstall Jenkins FIRST (stop any mid-build agents)
#   - Delete Jenkins PVC (EBS volume not known to Terraform — costs money if left)
#   - Wait for TWO ALBs (app + Jenkins) to be deleted
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/terraform"
NAMESPACE=$(terraform output -raw k8s_namespace 2>/dev/null || echo devops-app)
S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || true)
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || true)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo us-east-1)
# REVIEW FIX 4.7 — captured HERE, before destroy. After destroy the state is
# empty and `terraform output` returns nothing, so reading it at verification
# time would silently fall back to the default and check the wrong tag.
PROJECT_NAME=$(terraform output -raw project_name 2>/dev/null || echo vm-order)

echo "============================================"
echo "  VM Order Portal — Destroy"
echo "============================================"

# --- 1. Uninstall Jenkins FIRST (stop agents, release PVC) ---
echo ""
echo "Step 1: Uninstalling Jenkins..."
"$REPO_ROOT/scripts/uninstall-jenkins.sh" || echo "  (jenkins not installed)"

# --- 2. Remove ALB controller webhooks ---
echo ""
echo "Step 2: Removing ALB controller webhook configurations..."
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true

# --- 3. Uninstall app charts (frontend first — its Ingress owns the ALB) ---
# HELM_DRIVER=configmap ONLY for these three: the pipeline installed them with
# the configmap driver (so Jenkins never needed secrets access). With the
# default driver Helm would report "release: not found" and leave them running.
# The add-ons above/below were installed from this machine with the default
# driver, so they must NOT get this variable.
echo ""
echo "Step 3: Uninstalling application charts..."
HELM_DRIVER=configmap helm uninstall frontend -n "$NAMESPACE" 2>/dev/null || echo "  (frontend not installed)"
HELM_DRIVER=configmap helm uninstall worker   -n "$NAMESPACE" 2>/dev/null || echo "  (worker not installed)"
HELM_DRIVER=configmap helm uninstall backend  -n "$NAMESPACE" 2>/dev/null || echo "  (backend not installed)"

# --- 4. Wait until ALL ALBs are deleted (app + Jenkins) ---
echo ""
echo "Step 4: Waiting for ALBs to be deleted (up to 3 minutes)..."
for i in $(seq 1 18); do
    ALBS=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, \`k8s\`)].LoadBalancerArn" \
        --output text 2>/dev/null || true)
    [ -z "$ALBS" ] && { echo "✅ All ALBs gone"; break; }
    echo "  ... ALB(s) still deleting (attempt $i/18)"
    sleep 10
done

# --- 5. Remove add-ons ---
echo ""
echo "Step 5: Uninstalling add-ons..."
# Phase 5: the observability stack, BEFORE the ALB controller.
#
# Grafana's Ingress owns a real ALB, and the controller is what deletes it. Tear
# the controller down first and the ALB is orphaned: terraform destroy then
# fails on a VPC that still has a load balancer in it, and the bill continues.
# Same reasoning already applies to the application and Jenkins Ingresses above.
echo "  observability..."
helm uninstall observability -n observability 2>/dev/null || echo "  (observability chart not installed)"
helm uninstall kube-prometheus-stack -n observability 2>/dev/null || echo "  (kube-prometheus-stack not installed)"
# The CRDs are applied outside Helm, so Helm does not remove them. Left behind
# they keep the namespace from terminating.
kubectl delete crd -l app.kubernetes.io/name=kube-prometheus-stack-prometheus-operator 2>/dev/null || true
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents \
           prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
    kubectl delete crd "${crd}.monitoring.coreos.com" --ignore-not-found --wait=false 2>/dev/null || true
done

helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall metrics-server -n kube-system 2>/dev/null || true

# --- 6. Clean up Jenkins namespace ---
echo ""
echo "Step 6: Deleting Jenkins namespace..."
kubectl delete namespace jenkins --wait=false 2>/dev/null || true
kubectl delete namespace observability --wait=false 2>/dev/null || true

# --- 7. Empty the S3 bucket, INCLUDING versioned objects ---
if [ -n "$S3_BUCKET" ]; then
    echo ""
    echo "Step 7: Emptying S3 bucket ${S3_BUCKET}..."
    aws s3 rm "s3://${S3_BUCKET}" --recursive 2>/dev/null || echo "  (bucket empty or missing — continuing)"
    # AUDIT FIX -- this used to be a single list + single delete, and both APIs
    # cap at 1000. A bucket with more than 1000 object versions or delete
    # markers was never emptied; `|| true` swallowed the failure, and
    # `terraform destroy` then died on BucketNotEmpty several minutes later
    # with no hint that the sweep had silently stopped a thousand objects in.
    #
    # Delete markers matter as much as versions here: `aws s3 rm --recursive`
    # above CREATES one per object on a versioned bucket, so a bucket that
    # looks empty can still hold thousands of them.
    purged=0
    while :; do
        VERSIONS=$(aws s3api list-object-versions --bucket "$S3_BUCKET" --max-items 1000 \
            --output json \
            --query '{Objects: [Versions, DeleteMarkers][].{Key:Key,VersionId:VersionId}}' \
            2>/dev/null || true)
        if [ -z "$VERSIONS" ] || [ "$VERSIONS" = "null" ] || echo "$VERSIONS" | grep -q '"Objects": null'; then
            break
        fi
        N=$(printf '%s' "$VERSIONS" | grep -c '"VersionId"' || true)
        [ "${N:-0}" -eq 0 ] && break
        if ! aws s3api delete-objects --bucket "$S3_BUCKET" --delete "$VERSIONS" >/dev/null 2>&1; then
            echo "  WARNING: could not delete a batch of object versions." >&2
            echo "           terraform destroy will fail on BucketNotEmpty." >&2
            break
        fi
        purged=$((purged + N))
        echo "  purged ${purged} object versions..."
    done
fi

# --- 8. Terraform destroy, with orphan-ENI sweep + retry on failure ---
sweep_orphan_enis() {
    [ -z "$VPC_ID" ] && return 0
    echo "Sweeping orphaned network interfaces in ${VPC_ID}..."
    for ENI in $(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
        --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null); do
        echo "  deleting orphan ENI: $ENI"
        aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$ENI" 2>/dev/null || true
    done
}

# The ALB controller creates security groups (k8s-traffic-*, k8s-<ns>-<ing>-*)
# that Terraform does not know about. Deleting the ALB does not always remove
# them, and a VPC cannot be deleted while non-default security groups remain —
# so terraform destroy hangs on the VPC for 10+ minutes with no useful error.
sweep_orphan_sgs() {
    [ -z "$VPC_ID" ] && return 0
    echo "Sweeping orphaned k8s security groups in ${VPC_ID}..."
    # AUDIT FIX -- this used to select GroupName!='default', which is EVERY
    # security group in the VPC except the default one: the EKS cluster SG, the
    # node SG and the RDS SG that Terraform owns, as well as the orphans.
    #
    # The name of the function, the message above and the comment below all say
    # "orphaned k8s security groups"; the query said "all of them". Since this
    # runs BEFORE `terraform destroy` (step 8, not only on the retry path), a
    # destroy that then failed for any reason left a cluster whose own security
    # groups had every ingress and egress rule revoked -- nodes unable to reach
    # the API server, the API server unable to reach the nodes, and no way back
    # short of rebuilding, because `terraform apply` will not restore rules it
    # believes it already created.
    #
    # The orphans this is actually for are the ALB controller's, which are
    # named k8s-* and tagged with the cluster. Both are matched: the tag is
    # authoritative and the name prefix catches groups created before the
    # controller started tagging.
    SGS=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query "SecurityGroups[?starts_with(GroupName, 'k8s-') || not_null(Tags[?starts_with(Key, 'kubernetes.io/cluster/')] | [0])].GroupId" \
        --output text 2>/dev/null)
    [ -z "$SGS" ] && { echo "  none found"; return 0; }
    echo "  matched: $SGS"

    # Strip rules first: these groups reference each other, so a straight
    # delete fails with DependencyViolation.
    for SG in $SGS; do
        IN=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG" \
            --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
        EG=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG" \
            --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)
        if [ -n "$IN" ] && [ "$IN" != "[]" ]; then
            aws ec2 revoke-security-group-ingress --region "$AWS_REGION" \
                --group-id "$SG" --ip-permissions "$IN" >/dev/null 2>&1 || true
        fi
        if [ -n "$EG" ] && [ "$EG" != "[]" ]; then
            aws ec2 revoke-security-group-egress --region "$AWS_REGION" \
                --group-id "$SG" --ip-permissions "$EG" >/dev/null 2>&1 || true
        fi
    done

    for SG in $SGS; do
        echo "  deleting orphan SG: $SG"
        aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG" 2>/dev/null || true
    done
}

# Clear ALB-controller security groups BEFORE destroy, not just on retry:
# they are the most common reason the VPC delete stalls for 10+ minutes.
echo ""
echo "Step 8: Sweeping ALB-controller leftovers..."
sweep_orphan_sgs

echo ""
echo "Step 9: terraform destroy (10-15 minutes)..."
if ! terraform destroy -auto-approve; then
    echo ""
    echo "⚠️  Destroy hit a snag (usually orphaned EKS network interfaces)."
    echo "    Sweeping and retrying once..."
    sweep_orphan_enis
    sweep_orphan_sgs
    terraform destroy -auto-approve
fi

echo ""
echo "============================================"
echo "✅ terraform destroy completed"
echo "============================================"

# REVIEW FIX 4.7 — the old advice was "aws eks list-clusters (should be empty)".
# That is account-wide: it tells you nothing if a colleague has a cluster in the
# same account, and it says "not empty" for resources this project never owned.
# It also only checked EKS, so a leftover NAT Gateway or RDS instance — the two
# things that actually keep billing — went unmentioned.
#
# Verify by TAG instead. Every module tags its resources Project/Environment
# (see local.tags), so the question becomes "is anything of OURS still alive?",
# which is both answerable and the one that matters for the bill.
echo ""
echo "Verifying nothing tagged Project=${PROJECT_NAME:-vm-order} is left..."

leftovers=0
unanswered=0
report() {   # $1=label  $2=count (empty or non-numeric = the query FAILED)
    # AUDIT FIX. This used to be `[ "${2:-0}" -gt 0 ]`, so an AWS call that
    # failed produced an empty string, defaulted to 0, and printed "✅ none".
    #
    # Expired credentials, the wrong region, a missing permission or throttling
    # break all six queries at once, so the script printed a full page of green
    # ticks and "Nothing left — back to $0/hour" while the NAT gateways, the
    # RDS instance and the EKS cluster carried on billing. The one thing this
    # section exists to tell you is the one thing it got wrong, and it got it
    # wrong in the reassuring direction.
    #
    # "I could not ask" is now its own outcome, distinct from "the answer is
    # zero", and it is counted so the summary cannot claim success.
    case "${2:-}" in
        ''|*[!0-9]*)
            echo "   ❓ $1: COULD NOT CHECK (the AWS query failed)"
            unanswered=$((unanswered + 1))
            return
            ;;
    esac
    if [ "$2" -gt 0 ]; then
        echo "   ⚠️  $1: $2 still present"
        leftovers=$((leftovers + 1))
    else
        echo "   ✅ $1: none"
    fi
}

TAG_FILTER="Name=tag:Project,Values=${PROJECT_NAME:-vm-order}"

report "EC2 instances" "$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "$TAG_FILTER" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null)"

report "NAT Gateways (\$0.045/hr each)" "$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter "$TAG_FILTER" "Name=state,Values=available,pending" \
    --query 'length(NatGateways)' --output text 2>/dev/null)"

report "VPCs" "$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --filters "$TAG_FILTER" --query 'length(Vpcs)' --output text 2>/dev/null)"

# AUDIT FIX -- this matched LoadBalancerName against the project name, but this
# stack's ALBs are created by the AWS Load Balancer Controller and named k8s-*,
# which step 4 of this very script relies on. The check could therefore never
# report a leftover load balancer, which is one of the more expensive things to
# leave running. Both naming schemes are matched now.
report "Load balancers" "$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "length(LoadBalancers[?contains(LoadBalancerName, '${PROJECT_NAME:-vm-order}') || starts_with(LoadBalancerName, 'k8s-')])" \
    --output text 2>/dev/null)"

# EKS and RDS do not support tag filters on their list APIs, so match by the
# project name prefix that every resource here is named with.
report "EKS clusters" "$(aws eks list-clusters --region "$AWS_REGION" \
    --query "length(clusters[?contains(@, '${PROJECT_NAME:-vm-order}')])" --output text 2>/dev/null)"

report "RDS instances" "$(aws rds describe-db-instances --region "$AWS_REGION" \
    --query "length(DBInstances[?contains(DBInstanceIdentifier, '${PROJECT_NAME:-vm-order}')])" \
    --output text 2>/dev/null)"

echo ""
if [ "$unanswered" -gt 0 ]; then
    # A partial answer must never be presented as a clean bill of health: the
    # whole point of this section is the monthly bill.
    echo "============================================"
    echo "❓ ${unanswered} of the checks could not run."
    echo "   This is NOT 'nothing left'. Resources may still be billing and"
    echo "   this script could not see them."
    echo "   Usually expired credentials or the wrong region. Check with:"
    echo "     aws sts get-caller-identity --region ${AWS_REGION}"
    echo "   then re-run ./scripts/destroy.sh"
    echo "============================================"
    exit 1
fi
if [ "$leftovers" -eq 0 ]; then
    echo "============================================"
    echo "✅ Nothing left — back to \$0/hour"
    echo "============================================"
else
    echo "============================================"
    echo "⚠️  $leftovers resource type(s) still present."
    echo "   These are STILL BILLING. Re-run ./scripts/destroy.sh,"
    echo "   or delete them in the console if destroy keeps failing."
    echo "============================================"
    exit 1
fi
