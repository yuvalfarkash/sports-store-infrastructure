#!/usr/bin/env bash
set -euo pipefail

INFRA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$INFRA_ROOT/terraform"
CLOUDFRONT_DIR="$TERRAFORM_DIR/cloudfront"

# shellcheck source=scripts/cloudfront-common.sh
source "$INFRA_ROOT/scripts/cloudfront-common.sh"
# shellcheck source=scripts/aws-account-safety.sh
source "$INFRA_ROOT/scripts/aws-account-safety.sh"

readonly APP_NAMESPACE="sports-store"
readonly ARGOCD_NAMESPACE="argocd"
readonly ARGOCD_APPLICATION="sports-store"
readonly INGRESS_NAME="sports-store"
readonly GITHUB_ORGANIZATION="sports-store-devops-team"
readonly -a APPLICATION_REPOSITORIES=(
  "sports-store-frontend"
  "sports-store-auth-service"
  "sports-store-catalog-service"
  "sports-store-cart-service"
  "sports-store-order-service"
  "sports-store-payment-service"
)

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

configure_github_actions_variables() {
  local aws_region="$1"
  local publishing_role_arn="$2"
  local repository

  gh auth status >/dev/null
  for repository in "${APPLICATION_REPOSITORIES[@]}"; do
    gh variable set AWS_REGION --body "$aws_region" \
      -R "$GITHUB_ORGANIZATION/$repository"
    gh variable set AWS_ECR_PUBLISH_ROLE_ARN --body "$publishing_role_arn" \
      -R "$GITHUB_ORGANIZATION/$repository"
    [[ "$(gh variable get AWS_REGION -R "$GITHUB_ORGANIZATION/$repository" \
      --json value --jq .value)" == "$aws_region" ]] || return 1
    [[ "$(gh variable get AWS_ECR_PUBLISH_ROLE_ARN -R "$GITHUB_ORGANIZATION/$repository" \
      --json value --jq .value)" == "$publishing_role_arn" ]] || return 1
  done
}

trigger_application_workflows() {
  local repository run_id

  echo "=== Triggering and waiting for main-branch application workflows ==="
  for repository in "${APPLICATION_REPOSITORIES[@]}"; do
    echo "Rerunning the latest main push CI for $repository"
    run_id="$(gh run list -R "$GITHUB_ORGANIZATION/$repository" --workflow ci.yaml \
      --branch main --event push --limit 1 --json databaseId --jq '.[0].databaseId')"
    [[ -n "$run_id" ]] || {
      printf 'ERROR: no main push workflow exists for %s; refusing to bypass its publish gate.\n' \
        "$repository" >&2
      return 1
    }
    gh run rerun "$run_id" -R "$GITHUB_ORGANIZATION/$repository"
    gh run watch "$run_id" -R "$GITHUB_ORGANIZATION/$repository" --exit-status
  done
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
  local publishing_role_arn

  verify_expected_aws_identity
  validate_wait_configuration

  terraform -chdir="$TERRAFORM_DIR" init -input=false
  terraform -chdir="$CLOUDFRONT_DIR" init -input=false
  verify_terraform_state_account "$TERRAFORM_DIR"
  verify_terraform_state_account "$CLOUDFRONT_DIR"

  echo "=== Stage 1: provisioning base infrastructure and GitOps components ==="
  terraform -chdir="$TERRAFORM_DIR" apply -auto-approve -input=false

  cluster_name="$(terraform -chdir="$TERRAFORM_DIR" output -raw eks_cluster_name)"
  aws_region="$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_region)"
  publishing_role_arn="$(terraform -chdir="$TERRAFORM_DIR" output -raw github_actions_ecr_publishing_role_arn)"
  if [[ -z "$cluster_name" || "$aws_region" != "$EXPECTED_AWS_REGION" ||
    "$publishing_role_arn" != "arn:aws:iam::${EXPECTED_AWS_ACCOUNT_ID}:role/"* ]]; then
    echo "ERROR: Terraform returned unexpected deployment metadata." >&2
    return 1
  fi

  echo "=== Configuring approved repositories for OIDC-based ECR publication ==="
  configure_github_actions_variables "$aws_region" "$publishing_role_arn"
  trigger_application_workflows

  echo "=== Bootstrapping the first application secret version ==="
  bash "$INFRA_ROOT/scripts/bootstrap-application-secrets.sh" --ensure

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
