#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deploy.sh
source "$TEST_ROOT/deploy.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

declare -A VARIABLES=()
declare -a SET_REPOSITORIES=()

gh() {
  local command="$1"
  shift

  case "$command:$1" in
    'auth:status') return 0 ;;
    'variable:set')
      local name="$2" value='' repository=''
      shift 2
      while (($# > 0)); do
        case "$1" in
          --body) value="$2"; shift 2 ;;
          -R) repository="$2"; shift 2 ;;
          *) return 1 ;;
        esac
      done
      [[ "$repository" == sports-store-devops-team/* ]] || return 1
      VARIABLES["$repository:$name"]="$value"
      SET_REPOSITORIES+=("$repository")
      ;;
    'variable:get')
      local name="$2" repository=''
      shift 2
      while (($# > 0)); do
        case "$1" in
          -R) repository="$2"; shift 2 ;;
          --json|--jq) shift 2 ;;
          *) return 1 ;;
        esac
      done
      printf '%s\n' "${VARIABLES["$repository:$name"]:-}"
      ;;
    *) return 1 ;;
  esac
}

ROLE_ARN='arn:aws:iam::123456789012:role/sports-store-github-ecr-publisher'
STATIC_ROLE_ARN='arn:aws:iam::123456789012:role/sports-store-github-static-site-publisher'
STATIC_BUCKET='sports-store-static-123456789012-eu-central-1'
configure_frontend_github_actions_variables eu-central-1 "$STATIC_ROLE_ARN" "$STATIC_BUCKET" || fail "frontend variable configuration failed"
configure_backend_github_actions_variables eu-central-1 "$ROLE_ARN" || fail "backend variable configuration failed"
configure_frontend_github_actions_variables eu-central-1 "$STATIC_ROLE_ARN" "$STATIC_BUCKET" || fail "idempotent frontend configuration failed"
configure_backend_github_actions_variables eu-central-1 "$ROLE_ARN" || fail "idempotent backend configuration failed"

[[ ${#VARIABLES[@]} -eq 13 ]] || fail "expected three frontend and two variables for five backend repositories"
for repository in "${BACKEND_REPOSITORIES[@]}"; do
  full_name="$GITHUB_ORGANIZATION/$repository"
  [[ "${VARIABLES["$full_name:AWS_REGION"]}" == 'eu-central-1' ]] || fail "region missing for $repository"
  [[ "${VARIABLES["$full_name:AWS_ECR_PUBLISH_ROLE_ARN"]}" == "$ROLE_ARN" ]] || fail "role missing for $repository"
done
frontend_repository="$GITHUB_ORGANIZATION/sports-store-frontend"
[[ "${VARIABLES["$frontend_repository:AWS_REGION"]}" == 'eu-central-1' ]] || fail "frontend region missing"
[[ "${VARIABLES["$frontend_repository:AWS_STATIC_SITE_ROLE_ARN"]}" == "$STATIC_ROLE_ARN" ]] || fail "frontend role missing"
[[ "${VARIABLES["$frontend_repository:AWS_STATIC_SITE_BUCKET"]}" == "$STATIC_BUCKET" ]] || fail "frontend bucket missing"
[[ -z "${VARIABLES["$frontend_repository:AWS_ECR_PUBLISH_ROLE_ARN"]:-}" ]] || fail "frontend received shared ECR role"
if printf '%s\n' "${SET_REPOSITORIES[@]}" | grep -q 'sports-store-gateway'; then
  fail "Gateway repository was configured"
fi

printf 'GitHub Actions variable configuration scope validated with mocked gh.\n'
