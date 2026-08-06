#!/usr/bin/env bash
set -euo pipefail

# Root of the infrastructure repo
INFRA_ROOT="$(git rev-parse --show-toplevel)"
cd "$INFRA_ROOT/terraform"

VPC_ID="$(terraform output -raw vpc_id 2>/dev/null || true)"

echo "=== Deleting the ArgoCD Application first ==="
# Its syncPolicy.automated.selfHeal will otherwise recreate the Ingress
# (and therefore a brand-new ALB) the moment we delete it below - this bit
# us for real: a self-healed Ingress got a fresh ALB mid-destroy, after the
# AWS Load Balancer Controller that would have cleaned it up via finalizer
# was already gone, leaving an orphaned ALB blocking VPC teardown. Deleting
# the Application (not --cascade, no finalizer is set on it) only stops
# ArgoCD from managing things going forward - it does not touch the actual
# K8s resources, which is what we want since we handle the Ingress next.
kubectl delete application sports-store -n argocd --ignore-not-found=true --wait=true --timeout=30s 2>/dev/null || true

echo "=== Capturing ALB hostname(s) from any Ingress before deleting it ==="
HOSTNAMES="$(kubectl get ingress -n default -o jsonpath='{.items[*].status.loadBalancer.ingress[*].hostname}' 2>/dev/null || true)"

echo "=== Deleting Ingress(es) in the default namespace ==="
kubectl delete ingress --all -n default --ignore-not-found=true

if [[ -n "$HOSTNAMES" ]]; then
  echo "=== Waiting for the ALB(s) to actually disappear: $HOSTNAMES ==="
  for i in $(seq 1 30); do
    STILL_UP=0
    for HOSTNAME in $HOSTNAMES; do
      if aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='${HOSTNAME}']" --output text 2>/dev/null | grep -q .; then
        STILL_UP=1
      fi
    done
    if [[ "$STILL_UP" == "0" ]]; then
      echo "ALB(s) gone."
      break
    fi
    echo "Still waiting for ALB teardown... ($i/30, ~10s each)"
    sleep 10
  done
else
  echo "No Ingress/ALB found - nothing to wait for."
fi

if [[ -n "$VPC_ID" ]]; then
  echo "=== Removing any AWS Load Balancer Controller security groups left in $VPC_ID ==="
  # These are created imperatively by the controller (not Terraform-managed),
  # tagged elbv2.k8s.aws/cluster - if any survive, `terraform destroy` fails
  # on the VPC itself with a DependencyViolation, only discoverable after a
  # long retry loop. Clean them up proactively instead.
  LEFTOVER_SGS="$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)"
  for SG in $LEFTOVER_SGS; do
    echo "Deleting leftover security group $SG"
    aws ec2 delete-security-group --group-id "$SG" 2>&1 || echo "  (couldn't delete $SG yet - terraform destroy may still clear its dependents first)"
  done
else
  echo "=== Skipping leftover-SG check: could not read vpc_id output (already destroyed?) ==="
fi

echo "=== Running Terraform destroy ==="
echo "Note: ECR repos are force_delete=true - any pushed images will be deleted too."
terraform destroy

echo "=== Checking for orphaned EBS volumes (MongoDB PVC uses reclaimPolicy: Retain, so its volume survives this destroy) ==="
aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].{VolumeId:VolumeId,SizeGiB:Size}" --output table || true
