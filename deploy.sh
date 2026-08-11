#!/usr/bin/env bash
set -euo pipefail

INFRA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$INFRA_ROOT/terraform"
CLOUDFRONT_DIR="$TERRAFORM_DIR/cloudfront"

# shellcheck source=scripts/cloudfront-common.sh
source "$INFRA_ROOT/scripts/cloudfront-common.sh"

readonly APP_NAMESPACE="sports-store"
readonly ARGOCD_NAMESPACE="argocd"
readonly ARGOCD_APPLICATION="sports-store"
readonly INGRESS_NAME="sports-store"

ARGO_APPLICATION_TIMEOUT_SECONDS="${ARGO_APPLICATION_TIMEOUT_SECONDS:-300}"
ALB_HOSTNAME_TIMEOUT_SECONDS="${ALB_HOSTNAME_TIMEOUT_SECONDS:-1200}"
KUBERNETES_POLL_SECONDS="${KUBERNETES_POLL_SECONDS:-10}"

validate_wait_configuration() {
  local setting_name

  for setting_name in \
    ARGO_APPLICATION_TIMEOUT_SECONDS \
    ALB_HOSTNAME_TIMEOUT_SECONDS \
    KUBERNETES_POLL_SECONDS; do
    if ! is_positive_integer "${!setting_name}"; then
      printf 'ERROR: %s must be a positive integer, got %q.\n' \
        "$setting_name" "${!setting_name}" >&2
      return 1
    fi
  done
}

trigger_application_workflows() {
  local repositories=(
    "sports-store-frontend"
    "sports-store-auth-service"
    "sports-store-catalog-service"
    "sports-store-cart-service"
    "sports-store-order-service"
    "sports-store-payment-service"
  )
  local organization="sports-store-devops-team"
  local repository

  echo "=== Triggering CI workflows for all microservices ==="
  for repository in "${repositories[@]}"; do
    echo "Triggering CI for $repository"
    gh workflow run ci.yaml -R "$organization/$repository" --ref main ||
      echo "Failed to trigger CI for $repository"
  done
  echo "All triggers dispatched."
}

apply_cloudfront() {
  local alb_hostname="$1"
  local aws_region="$2"

  echo "=== Stage 2: creating or updating Terraform-managed CloudFront ==="
  terraform -chdir="$CLOUDFRONT_DIR" init -input=false
  terraform -chdir="$CLOUDFRONT_DIR" apply \
    -auto-approve \
    -input=false \
    "-var=alb_origin_hostname=$alb_hostname" \
    "-var=aws_region=$aws_region"
}

main() {
  local cluster_name
  local aws_region
  local alb_hostname
  local cloudfront_domain
  local cloudfront_url

  validate_wait_configuration

  echo "=== Stage 1: provisioning base infrastructure and GitOps components ==="
  terraform -chdir="$TERRAFORM_DIR" init -input=false
  terraform -chdir="$TERRAFORM_DIR" apply -auto-approve -input=false

  printf '%s\n' \
    '=== Application secret bootstrap is manual ===' \
    'Terraform created the AWS Secrets Manager container but did not create a secret version.' \
    'From the repository root, verify identity and status, then populate the first version:' \
    '  bash scripts/bootstrap-application-secrets.sh --check' \
    '  bash scripts/bootstrap-application-secrets.sh' \
    'Do not use --rotate during a normal deployment.'

  trigger_application_workflows

  cluster_name="$(terraform -chdir="$TERRAFORM_DIR" output -raw eks_cluster_name)"
  aws_region="$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_region)"
  if [[ -z "$cluster_name" || -z "$aws_region" ]]; then
    echo "ERROR: Terraform did not return the EKS cluster name and AWS region." >&2
    return 1
  fi

  echo "=== Configuring kubectl for cluster $cluster_name in $aws_region ==="
  aws eks update-kubeconfig --name "$cluster_name" --region "$aws_region"

  echo "=== Waiting for the Argo CD application ==="
  wait_for_kubernetes_object \
    application.argoproj.io \
    "$ARGOCD_APPLICATION" \
    "$ARGOCD_NAMESPACE" \
    "$ARGO_APPLICATION_TIMEOUT_SECONDS" \
    "$KUBERNETES_POLL_SECONDS"

  echo "=== Waiting for the Sports Store Ingress ALB hostname ==="
  alb_hostname="$(wait_for_alb_hostname \
    "$INGRESS_NAME" \
    "$APP_NAMESPACE" \
    "$ALB_HOSTNAME_TIMEOUT_SECONDS" \
    "$KUBERNETES_POLL_SECONDS")"

  apply_cloudfront "$alb_hostname" "$aws_region"

  cloudfront_domain="$(terraform -chdir="$CLOUDFRONT_DIR" output -raw cloudfront_domain_name)"
  cloudfront_url="$(terraform -chdir="$CLOUDFRONT_DIR" output -raw cloudfront_https_url)"
  if [[ ! "$cloudfront_domain" =~ ^[A-Za-z0-9]+\.cloudfront\.net$ ]] ||
    [[ "$cloudfront_url" != "https://$cloudfront_domain" ]]; then
    echo "ERROR: Terraform returned an unexpected CloudFront URL." >&2
    return 1
  fi

  printf '%s\n' \
    "CloudFront URL: $cloudfront_url" \
    "Direct ALB URL (troubleshooting): http://$alb_hostname"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
