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
readonly -a BACKEND_REPOSITORIES=(
  "sports-store-auth-service"
  "sports-store-catalog-service"
  "sports-store-cart-service"
  "sports-store-order-service"
  "sports-store-payment-service"
)

ARGO_APPLICATION_TIMEOUT_SECONDS="${ARGO_APPLICATION_TIMEOUT_SECONDS:-300}"
ALB_HOSTNAME_TIMEOUT_SECONDS="${ALB_HOSTNAME_TIMEOUT_SECONDS:-1200}"
KUBERNETES_POLL_SECONDS="${KUBERNETES_POLL_SECONDS:-10}"
WORKFLOW_DISCOVERY_TIMEOUT_SECONDS="${WORKFLOW_DISCOVERY_TIMEOUT_SECONDS:-120}"
GITHUB_ACTIONS_POLL_SECONDS="${GITHUB_ACTIONS_POLL_SECONDS:-5}"

validate_wait_configuration() {
  local setting_name

  for setting_name in \
    ARGO_APPLICATION_TIMEOUT_SECONDS \
    ALB_HOSTNAME_TIMEOUT_SECONDS \
    KUBERNETES_POLL_SECONDS \
    WORKFLOW_DISCOVERY_TIMEOUT_SECONDS \
    GITHUB_ACTIONS_POLL_SECONDS; do
    if ! is_positive_integer "${!setting_name}"; then
      printf 'ERROR: %s must be a positive integer, got %q.\n' \
        "$setting_name" "${!setting_name}" >&2
      return 1
    fi
  done
}

get_remote_main_sha() {
  local repository="$1"
  local main_sha

  main_sha="$(gh api "repos/$GITHUB_ORGANIZATION/$repository/git/ref/heads/main" \
    --jq '.object.sha')"
  if [[ ! "$main_sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'ERROR: remote main for %s did not resolve to a full lowercase commit SHA.\n' \
      "$repository" >&2
    return 1
  fi
  printf '%s\n' "$main_sha"
}

generate_deployment_id() {
  local repository="$1"
  local repository_slug="${repository#sports-store-}"
  local deployment_id

  deployment_id="deploy-$(date -u +%Y%m%dT%H%M%S%NZ)-${repository_slug}-$$"
  if [[ ! "$deployment_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo 'ERROR: generated deployment identifier is invalid.' >&2
    return 1
  fi
  printf '%s\n' "$deployment_id"
}

find_dispatched_run() {
  local repository="$1"
  local expected_sha="$2"
  local deployment_id="$3"
  local baseline_run_id="$4"
  local expected_title="Deploy $deployment_id"
  local deadline=$((SECONDS + WORKFLOW_DISCOVERY_TIMEOUT_SECONDS))
  local runs run_id display_title event head_branch head_sha
  local candidate_event candidate_head_branch candidate_head_sha
  local -a candidate_run_ids

  if [[ ! "$expected_sha" =~ ^[0-9a-f]{40}$ ]] ||
    [[ ! "$deployment_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    [[ ! "$baseline_run_id" =~ ^[0-9]+$ ]] ||
    ! is_positive_integer "$WORKFLOW_DISCOVERY_TIMEOUT_SECONDS" ||
    ! is_positive_integer "$GITHUB_ACTIONS_POLL_SECONDS"; then
    echo 'ERROR: invalid workflow correlation parameters.' >&2
    return 1
  fi

  while ((SECONDS < deadline)); do
    runs="$(gh run list -R "$GITHUB_ORGANIZATION/$repository" \
      --workflow ci.yaml --limit 100 \
      --json databaseId,displayTitle,event,headBranch,headSha \
      --jq '.[] | [.databaseId, .displayTitle, .event, .headBranch, .headSha] | @tsv')"
    candidate_run_ids=()
    candidate_event=''
    candidate_head_branch=''
    candidate_head_sha=''
    while IFS=$'\t' read -r run_id display_title event head_branch head_sha; do
      [[ -n "$run_id" ]] || continue
      if [[ "$run_id" =~ ^[0-9]+$ ]] &&
        ((run_id > baseline_run_id)) &&
        [[ "$display_title" == "$expected_title" ]]; then
        candidate_run_ids+=("$run_id")
        candidate_event="$event"
        candidate_head_branch="$head_branch"
        candidate_head_sha="$head_sha"
      fi
    done <<<"$runs"

    if ((${#candidate_run_ids[@]} > 1)); then
      printf 'ERROR: multiple workflow runs matched deployment %s in %s.\n' \
        "$deployment_id" "$repository" >&2
      return 1
    fi
    if ((${#candidate_run_ids[@]} == 1)); then
      if [[ "$candidate_event" != 'workflow_dispatch' ]] ||
        [[ "$candidate_head_branch" != 'main' ]] ||
        [[ "$candidate_head_sha" != "$expected_sha" ]]; then
        printf 'ERROR: correlated workflow run metadata is unsafe for deployment %s in %s.\n' \
          "$deployment_id" "$repository" >&2
        return 1
      fi
      printf '%s\n' "${candidate_run_ids[0]}"
      return 0
    fi
    sleep "$GITHUB_ACTIONS_POLL_SECONDS"
  done

  printf 'ERROR: timed out correlating deployment %s in %s.\n' \
    "$deployment_id" "$repository" >&2
  return 1
}

configure_backend_github_actions_variables() {
  local aws_region="$1"
  local publishing_role_arn="$2"
  local repository

  gh auth status >/dev/null
  for repository in "${BACKEND_REPOSITORIES[@]}"; do
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

configure_frontend_github_actions_variables() {
  local aws_region="$1"
  local static_role_arn="$2"
  local static_bucket="$3"
  local repository="$GITHUB_ORGANIZATION/sports-store-frontend"

  gh auth status >/dev/null
  gh variable set AWS_REGION --body "$aws_region" -R "$repository"
  gh variable set AWS_STATIC_SITE_ROLE_ARN --body "$static_role_arn" -R "$repository"
  gh variable set AWS_STATIC_SITE_BUCKET --body "$static_bucket" -R "$repository"

  [[ "$(gh variable get AWS_REGION -R "$repository" --json value --jq .value)" == "$aws_region" ]] || return 1
  [[ "$(gh variable get AWS_STATIC_SITE_ROLE_ARN -R "$repository" --json value --jq .value)" == "$static_role_arn" ]] || return 1
  [[ "$(gh variable get AWS_STATIC_SITE_BUCKET -R "$repository" --json value --jq .value)" == "$static_bucket" ]] || return 1
}

trigger_application_workflows() {
  local repository expected_sha confirmed_sha deployment_id baseline_run_id run_id

  echo "=== Triggering and waiting for main-branch application workflows ==="
  for repository in "${APPLICATION_REPOSITORIES[@]}"; do
    echo "Dispatching the exact current main revision for $repository"
    expected_sha="$(get_remote_main_sha "$repository")"
    deployment_id="$(generate_deployment_id "$repository")"
    baseline_run_id="$(gh run list -R "$GITHUB_ORGANIZATION/$repository" \
      --workflow ci.yaml --limit 100 --json databaseId \
      --jq 'map(.databaseId) | max // 0')"
    [[ "$baseline_run_id" =~ ^[0-9]+$ ]] || {
      printf 'ERROR: could not establish the workflow run baseline for %s.\n' \
        "$repository" >&2
      return 1
    }

    confirmed_sha="$(get_remote_main_sha "$repository")"
    if [[ "$confirmed_sha" != "$expected_sha" ]]; then
      printf 'ERROR: remote main changed before dispatch for %s; refusing to continue.\n' \
        "$repository" >&2
      return 1
    fi

    gh workflow run ci.yaml -R "$GITHUB_ORGANIZATION/$repository" \
      --ref main \
      -f "expected_sha=$expected_sha" \
      -f "deployment_id=$deployment_id"
    run_id="$(find_dispatched_run \
      "$repository" "$expected_sha" "$deployment_id" "$baseline_run_id")"
    gh run watch "$run_id" -R "$GITHUB_ORGANIZATION/$repository" --exit-status
  done
}

apply_cloudfront() {
  local alb_hostname="$1"
  local aws_region="$2"
  local static_bucket_name="$3"
  local static_bucket_arn="$4"
  local static_bucket_domain="$5"

  echo "=== Stage 2: creating or updating Terraform-managed CloudFront ==="
  terraform -chdir="$CLOUDFRONT_DIR" init -input=false
  terraform -chdir="$CLOUDFRONT_DIR" apply \
    -auto-approve \
    -input=false \
    "-var=alb_origin_hostname=$alb_hostname" \
    "-var=aws_region=$aws_region" \
    "-var=static_site_bucket_name=$static_bucket_name" \
    "-var=static_site_bucket_arn=$static_bucket_arn" \
    "-var=static_site_bucket_regional_domain_name=$static_bucket_domain"
}

main() {
  local cluster_name
  local aws_region
  local alb_hostname
  local cloudfront_domain
  local cloudfront_url
  local publishing_role_arn
  local static_role_arn
  local static_bucket_name
  local static_bucket_arn
  local static_bucket_domain

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
  static_role_arn="$(terraform -chdir="$TERRAFORM_DIR" output -raw github_actions_static_site_publishing_role_arn)"
  static_bucket_name="$(terraform -chdir="$TERRAFORM_DIR" output -raw static_site_bucket_name)"
  static_bucket_arn="$(terraform -chdir="$TERRAFORM_DIR" output -raw static_site_bucket_arn)"
  static_bucket_domain="$(terraform -chdir="$TERRAFORM_DIR" output -raw static_site_bucket_regional_domain_name)"
  if [[ -z "$cluster_name" || "$aws_region" != "$EXPECTED_AWS_REGION" ||
    "$publishing_role_arn" != "arn:aws:iam::${EXPECTED_AWS_ACCOUNT_ID}:role/"* ||
    "$static_role_arn" != "arn:aws:iam::${EXPECTED_AWS_ACCOUNT_ID}:role/"* ||
    "$static_bucket_name" != "sports-store-static-${EXPECTED_AWS_ACCOUNT_ID}-${aws_region}" ||
    "$static_bucket_arn" != "arn:aws:s3:::${static_bucket_name}" ||
    "$static_bucket_domain" != "${static_bucket_name}.s3.${aws_region}.amazonaws.com" ]]; then
    echo "ERROR: Terraform returned unexpected deployment metadata." >&2
    return 1
  fi

  echo "=== Configuring the frontend for OIDC-based private S3 publication ==="
  configure_frontend_github_actions_variables "$aws_region" "$static_role_arn" "$static_bucket_name"

  echo "=== Configuring backend repositories for OIDC-based ECR publication ==="
  configure_backend_github_actions_variables "$aws_region" "$publishing_role_arn"
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

  apply_cloudfront \
    "$alb_hostname" \
    "$aws_region" \
    "$static_bucket_name" \
    "$static_bucket_arn" \
    "$static_bucket_domain"

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
