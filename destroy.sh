#!/usr/bin/env bash
set -euo pipefail

INFRA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$INFRA_ROOT/terraform"
CLOUDFRONT_DIR="$TERRAFORM_DIR/cloudfront"

# shellcheck source=scripts/cloudfront-common.sh
source "$INFRA_ROOT/scripts/cloudfront-common.sh"
# shellcheck source=scripts/aws-account-safety.sh
source "$INFRA_ROOT/scripts/aws-account-safety.sh"

ALB_DELETE_MAX_ATTEMPTS="${ALB_DELETE_MAX_ATTEMPTS:-30}"
ALB_DELETE_POLL_SECONDS="${ALB_DELETE_POLL_SECONDS:-10}"

terraform_state_list() {
  local terraform_directory="$1"
  local state_output

  if state_output="$(terraform -chdir="$terraform_directory" state list 2>&1)"; then
    printf '%s' "$state_output"
    return 0
  fi

  if [[ "$state_output" == *"No state file"* ]]; then
    return 0
  fi

  echo "ERROR: Unable to inspect Terraform state in $terraform_directory." >&2
  return 1
}

verify_expected_aws_identity

terraform -chdir="$CLOUDFRONT_DIR" init -input=false
terraform -chdir="$TERRAFORM_DIR" init -input=false
verify_terraform_state_account "$CLOUDFRONT_DIR"
verify_terraform_state_account "$TERRAFORM_DIR"

if ! is_positive_integer "$ALB_DELETE_MAX_ATTEMPTS" ||
  ! is_positive_integer "$ALB_DELETE_POLL_SECONDS"; then
  echo "ERROR: ALB delete wait settings must be positive integers." >&2
  exit 1
fi

echo "=== Destroying Terraform-managed CloudFront before the Ingress and ALB ==="
CLOUDFRONT_STATE_RESOURCES="$(terraform_state_list "$CLOUDFRONT_DIR")"
if [[ -n "$CLOUDFRONT_STATE_RESOURCES" ]]; then
  terraform -chdir="$CLOUDFRONT_DIR" destroy
else
  echo "No CloudFront-stage resources exist in Terraform state - nothing to destroy."
fi

VPC_ID="$(terraform -chdir="$TERRAFORM_DIR" output -raw vpc_id 2>/dev/null || true)"
AWS_REGION="$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_region 2>/dev/null || true)"
CLUSTER_NAME="$(terraform -chdir="$TERRAFORM_DIR" output -raw eks_cluster_name 2>/dev/null || true)"
BASE_STATE_RESOURCES="$(terraform_state_list "$TERRAFORM_DIR")"

if [[ -n "$BASE_STATE_RESOURCES" && -z "$AWS_REGION" ]]; then
  echo "ERROR: Base Terraform state exists but its aws_region output is unavailable." >&2
  exit 1
fi

if grep -q '^module\.eks\.' <<<"$BASE_STATE_RESOURCES"; then
  if [[ -z "$CLUSTER_NAME" ]]; then
    echo "ERROR: EKS remains in Terraform state but its cluster-name output is unavailable." >&2
    exit 1
  fi

  echo "=== Configuring kubectl for cluster $CLUSTER_NAME in $AWS_REGION ==="
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

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
  HOSTNAMES="$(kubectl get ingress -n sports-store -o jsonpath='{.items[*].status.loadBalancer.ingress[*].hostname}' 2>/dev/null || true)"

  for HOSTNAME in $HOSTNAMES; do
    if ! is_valid_alb_hostname "$HOSTNAME"; then
      printf 'ERROR: Refusing to use invalid Ingress hostname during destroy: %q\n' "$HOSTNAME" >&2
      exit 1
    fi
  done

  echo "=== Deleting Ingress(es) in the sports-store namespace ==="
  kubectl delete ingress --all -n sports-store --ignore-not-found=true
else
  echo "=== EKS is absent from Terraform state; skipping Kubernetes and ALB cleanup ==="
  HOSTNAMES=""
fi

if [[ -n "$HOSTNAMES" ]]; then
  echo "=== Waiting for the ALB(s) to actually disappear: $HOSTNAMES ==="
  ALBS_GONE=0
  for ((i = 1; i <= ALB_DELETE_MAX_ATTEMPTS; i++)); do
    STILL_UP=0
    for HOSTNAME in $HOSTNAMES; do
      if aws --region "$AWS_REGION" elbv2 describe-load-balancers \
        --query "LoadBalancers[?DNSName=='${HOSTNAME}']" \
        --output text 2>/dev/null | grep -q .; then
        STILL_UP=1
      fi
    done
    if [[ "$STILL_UP" == "0" ]]; then
      echo "ALB(s) gone."
      ALBS_GONE=1
      break
    fi
    if (( i < ALB_DELETE_MAX_ATTEMPTS )); then
      echo "Still waiting for ALB teardown... ($i/$ALB_DELETE_MAX_ATTEMPTS, ~${ALB_DELETE_POLL_SECONDS}s each)"
      sleep "$ALB_DELETE_POLL_SECONDS"
    fi
  done

  if [[ "$ALBS_GONE" == "0" ]]; then
    echo "ERROR: ALB teardown did not finish within the bounded wait; refusing to destroy the VPC." >&2
    exit 1
  fi
else
  echo "No Ingress/ALB found - nothing to wait for."
fi

if [[ -n "$VPC_ID" ]]; then
  echo "=== Removing any AWS Load Balancer Controller security groups left in $VPC_ID ==="
  # These are created imperatively by the controller (not Terraform-managed),
  # tagged elbv2.k8s.aws/cluster - if any survive, `terraform destroy` fails
  # on the VPC itself with a DependencyViolation, only discoverable after a
  # long retry loop. Clean them up proactively instead.
  LEFTOVER_SGS="$(aws --region "$AWS_REGION" ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)"
  for SG in $LEFTOVER_SGS; do
    echo "Deleting leftover security group $SG"
    aws --region "$AWS_REGION" ec2 delete-security-group --group-id "$SG" 2>&1 || echo "  (couldn't delete $SG yet - terraform destroy may still clear its dependents first)"
  done
else
  echo "=== Skipping leftover-SG check: could not read vpc_id output (already destroyed?) ==="
fi

echo "=== Running Terraform destroy ==="
echo "Note: ECR repos are force_delete=true - any pushed images will be deleted too."
terraform -chdir="$TERRAFORM_DIR" destroy

echo "=== Checking for orphaned EBS volumes (MongoDB PVC uses reclaimPolicy: Retain, so its volume survives this destroy) ==="
aws --region "$AWS_REGION" ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].{VolumeId:VolumeId,SizeGiB:Size}" --output table || true
