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
configure_github_actions_variables eu-central-1 "$ROLE_ARN" || fail "variable configuration failed"
configure_github_actions_variables eu-central-1 "$ROLE_ARN" || fail "idempotent configuration failed"

[[ ${#VARIABLES[@]} -eq 12 ]] || fail "expected two variables for six repositories"
for repository in "${APPLICATION_REPOSITORIES[@]}"; do
  full_name="$GITHUB_ORGANIZATION/$repository"
  [[ "${VARIABLES["$full_name:AWS_REGION"]}" == 'eu-central-1' ]] || fail "region missing for $repository"
  [[ "${VARIABLES["$full_name:AWS_ECR_PUBLISH_ROLE_ARN"]}" == "$ROLE_ARN" ]] || fail "role missing for $repository"
done
if printf '%s\n' "${SET_REPOSITORIES[@]}" | grep -q 'sports-store-gateway'; then
  fail "Gateway repository was configured"
fi

printf 'GitHub Actions variable configuration scope validated with mocked gh.\n'
