#!/usr/bin/env bash
set -euo pipefail

# Root of the infrastructure repo
INFRA_ROOT="$(git rev-parse --show-toplevel)"
cd "$INFRA_ROOT/terraform"

echo "=== Capturing ALB hostname(s) from any Ingress before deleting it ==="
# The AWS Load Balancer Controller creates the ALB imperatively, outside
# Terraform - it only tears it down via a finalizer that fires when the
# Ingress is deleted while the controller is still running. Deleting the
# Ingress first (and confirming the ALB is actually gone) avoids orphaning
# it once `terraform destroy` uninstalls the controller.
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

echo "=== Running Terraform destroy ==="
echo "Note: ECR repos are force_delete=true - any pushed images will be deleted too."
terraform destroy

echo "=== Checking for orphaned EBS volumes (MongoDB PVC uses reclaimPolicy: Retain, so its volume survives this destroy) ==="
aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].{VolumeId:VolumeId,SizeGiB:Size}" --output table || true
