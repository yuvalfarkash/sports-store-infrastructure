#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deploy.sh
source "$TEST_ROOT/deploy.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

readonly TEST_SHA='0123456789abcdef0123456789abcdef01234567'
readonly OTHER_SHA='abcdef0123456789abcdef0123456789abcdef01'
GH_MODE='success'
API_LOG_FILE="$(mktemp)"
trap 'rm -f -- "$API_LOG_FILE"' EXIT
declare -A DISPATCH_SHA=()
declare -A DISPATCH_ID=()
declare -a WATCHED_REPOSITORIES=()

gh() {
  local command="$1"
  shift
  local repository='' argument endpoint repo_name

  case "$command:$1" in
    'api:repos/'*)
      endpoint="$1"
      repo_name="${endpoint#repos/$GITHUB_ORGANIZATION/}"
      repo_name="${repo_name%/git/ref/heads/main}"
      printf '%s\n' "$repo_name" >>"$API_LOG_FILE"
      if [[ "$GH_MODE" == 'malformed' ]]; then
        printf 'not-a-sha\n'
      elif [[ "$GH_MODE" == 'drift' && $(grep -c -x "$repo_name" "$API_LOG_FILE") -gt 1 ]]; then
        printf '%s\n' "$OTHER_SHA"
      else
        printf '%s\n' "$TEST_SHA"
      fi
      ;;
    'run:list')
      while (($# > 0)); do
        case "$1" in
          -R) repository="$2"; shift 2 ;;
          --json)
            if [[ "$2" == 'databaseId' ]]; then
              printf '100\n'
              return 0
            fi
            shift 2
            ;;
          *) shift ;;
        esac
      done
      repo_name="${repository#${GITHUB_ORGANIZATION}/}"
      case "$GH_MODE" in
        wrong-sha)
          printf '101\tDeploy test-id\tworkflow_dispatch\tmain\t%s\n' "$OTHER_SHA"
          ;;
        duplicate)
          printf '101\tDeploy test-id\tworkflow_dispatch\tmain\t%s\n' "$TEST_SHA"
          printf '102\tDeploy test-id\tworkflow_dispatch\tmain\t%s\n' "$TEST_SHA"
          ;;
        *)
          if [[ -n "${DISPATCH_ID["$repo_name"]:-}" ]]; then
            printf '101\tDeploy %s\tworkflow_dispatch\tmain\t%s\n' \
              "${DISPATCH_ID["$repo_name"]}" "${DISPATCH_SHA["$repo_name"]}"
          fi
          ;;
      esac
      ;;
    'workflow:run')
      shift
      [[ "$1" == 'ci.yaml' ]] || return 1
      shift
      while (($# > 0)); do
        case "$1" in
          -R) repository="$2"; shift 2 ;;
          --ref) [[ "$2" == 'main' ]] || return 1; shift 2 ;;
          -f)
            argument="$2"
            case "$argument" in
              expected_sha=*) DISPATCH_SHA["${repository#${GITHUB_ORGANIZATION}/}"]="${argument#expected_sha=}" ;;
              deployment_id=*) DISPATCH_ID["${repository#${GITHUB_ORGANIZATION}/}"]="${argument#deployment_id=}" ;;
              *) return 1 ;;
            esac
            shift 2
            ;;
          *) return 1 ;;
        esac
      done
      ;;
    'run:watch')
      [[ "$2" == '101' ]] || return 1
      shift 2
      while (($# > 0)); do
        case "$1" in
          -R) WATCHED_REPOSITORIES+=("$2"); shift 2 ;;
          --exit-status) shift ;;
          *) return 1 ;;
        esac
      done
      ;;
    *) return 1 ;;
  esac
}

generated_id="$(generate_deployment_id sports-store-payment-service)"
[[ "$generated_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail "generated deployment ID is unsafe"

GH_MODE='malformed'
if get_remote_main_sha sports-store-auth-service >/dev/null 2>&1; then
  fail "malformed remote SHA was accepted"
fi

GH_MODE='wrong-sha'
if find_dispatched_run sports-store-auth-service "$TEST_SHA" test-id 100 >/dev/null 2>&1; then
  fail "a correlated run with the wrong SHA was accepted"
fi
if find_dispatched_run sports-store-auth-service invalid test-id 100 >/dev/null 2>&1; then
  fail "a malformed expected SHA was accepted for correlation"
fi
if find_dispatched_run sports-store-auth-service "$TEST_SHA" 'unsafe id' 100 >/dev/null 2>&1; then
  fail "an unsafe deployment ID was accepted for correlation"
fi

GH_MODE='duplicate'
if find_dispatched_run sports-store-auth-service "$TEST_SHA" test-id 100 >/dev/null 2>&1; then
  fail "multiple correlated runs were accepted"
fi

GH_MODE='drift'
: >"$API_LOG_FILE"
if trigger_application_workflows >/dev/null 2>&1; then
  fail "a main-branch change before dispatch was accepted"
fi
[[ ${#DISPATCH_ID[@]} -eq 0 ]] || fail "workflow was dispatched after main changed"

GH_MODE='success'
: >"$API_LOG_FILE"
DISPATCH_SHA=()
DISPATCH_ID=()
WATCHED_REPOSITORIES=()
trigger_application_workflows >/dev/null || fail "revision-safe workflow dispatch failed"
[[ ${#DISPATCH_ID[@]} -eq ${#APPLICATION_REPOSITORIES[@]} ]] || fail "not every application repository was dispatched"
[[ ${#WATCHED_REPOSITORIES[@]} -eq ${#APPLICATION_REPOSITORIES[@]} ]] || fail "not every exact run was watched"
for repo_name in "${APPLICATION_REPOSITORIES[@]}"; do
  [[ "$(grep -c -x "$repo_name" "$API_LOG_FILE")" -eq 2 ]] || fail "remote main was not checked twice for $repo_name"
  [[ "${DISPATCH_SHA["$repo_name"]}" == "$TEST_SHA" ]] || fail "wrong expected SHA sent for $repo_name"
  [[ "${DISPATCH_ID["$repo_name"]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail "unsafe deployment ID sent for $repo_name"
done

printf 'Revision-safe GitHub Actions dispatch validated with mocked gh.\n'
