#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# config/aws-environment.json is a git-ignored, developer-supplied file (real
# account ID/ARN); this test only needs a readable file for the file-existence
# check below, since jq is mocked and never actually parses its contents.
export AWS_ENVIRONMENT_FILE="$TEST_ROOT/config/aws-environment.json.example"
# shellcheck source=../scripts/aws-account-safety.sh
source "$TEST_ROOT/scripts/aws-account-safety.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

AWS_ACCOUNT='123456789012'
AWS_ARN='arn:aws:iam::123456789012:user/deploy-user'
AWS_RESPONSE_MODE='valid'
AWS_CALL_LOG="$(mktemp)"
trap 'rm -f "$AWS_CALL_LOG"' EXIT
aws() {
  printf 'call\n' >>"$AWS_CALL_LOG"
  [[ "$*" == 'sts get-caller-identity --output json' ]] || return 1
  case "$AWS_RESPONSE_MODE" in
    valid) printf '{"Account":"%s","Arn":"%s","UserId":"test"}\n' "$AWS_ACCOUNT" "$AWS_ARN" ;;
    missing) printf '{}\n' ;;
    failure) return 1 ;;
    *) return 1 ;;
  esac
}

jq() {
  local expression="${*: -1}"
  case "$expression" in
    '.expected_account_id | select(type == "string" and length > 0)') printf '123456789012\n' ;;
    '.aws_region | select(type == "string" and length > 0)') printf 'eu-central-1\n' ;;
    '.deployment_principal_arn | select(type == "string" and length > 0)') printf 'arn:aws:iam::123456789012:user/deploy-user\n' ;;
    '.Account | select(type == "string" and length > 0)') [[ "$AWS_RESPONSE_MODE" == valid ]] && printf '%s\n' "$AWS_ACCOUNT" ;;
    '.Arn | select(type == "string" and length > 0)') [[ "$AWS_RESPONSE_MODE" == valid ]] && printf '%s\n' "$AWS_ARN" ;;
    *) return 1 ;;
  esac
}

assert_identity_accepted() {
  local account="$1"
  local arn="$2"
  local description="$3"
  AWS_ACCOUNT="$account"
  AWS_ARN="$arn"
  AWS_RESPONSE_MODE='valid'
  : >"$AWS_CALL_LOG"
  verify_expected_aws_identity >/dev/null || fail "$description was rejected"
  [[ "$(wc -l <"$AWS_CALL_LOG")" -eq 1 ]] || fail "$description did not call AWS CLI exactly once"
}

assert_identity_rejected() {
  local account="$1"
  local arn="$2"
  local description="$3"
  AWS_ACCOUNT="$account"
  AWS_ARN="$arn"
  AWS_RESPONSE_MODE='valid'
  : >"$AWS_CALL_LOG"
  if verify_expected_aws_identity >/dev/null 2>&1; then
    fail "$description was accepted"
  fi
  [[ "$(wc -l <"$AWS_CALL_LOG")" -eq 1 ]] || fail "$description did not call AWS CLI exactly once"
}

assert_identity_accepted '123456789012' 'arn:aws:iam::123456789012:user/deploy-user' 'expected IAM user'
assert_identity_accepted '123456789012' 'arn:aws-us-gov:iam::123456789012:role/team/DeploymentRole' 'expected IAM role'
assert_identity_accepted '123456789012' 'arn:aws-cn:sts::123456789012:assumed-role/DeploymentRole/github-actions' 'expected assumed role'

assert_identity_rejected '999999999999' 'arn:aws:sts::999999999999:assumed-role/DeploymentRole/session' 'wrong-account assumed role'
assert_identity_rejected '999999999999' 'arn:aws:iam::999999999999:user/wrong' 'wrong-account IAM user'
assert_identity_rejected '123456789012' 'arn:aws:iam::123456789012:root' 'root identity'
assert_identity_rejected '123456789012' 'arn:aws:sts::123456789012:federated-user/example' 'federated user'
assert_identity_rejected '123456789012' 'arn:aws:iam::123456789012:role/' 'malformed ARN'

AWS_RESPONSE_MODE='missing'
: >"$AWS_CALL_LOG"
if verify_expected_aws_identity >/dev/null 2>&1; then
  fail "missing identity was accepted"
fi
[[ "$(wc -l <"$AWS_CALL_LOG")" -eq 1 ]] || fail "missing identity did not call AWS CLI exactly once"

AWS_RESPONSE_MODE='failure'
: >"$AWS_CALL_LOG"
if verify_expected_aws_identity >/dev/null 2>&1; then
  fail "AWS CLI failure was accepted"
fi
[[ "$(wc -l <"$AWS_CALL_LOG")" -eq 1 ]] || fail "AWS CLI failure did not call AWS CLI exactly once"

# shellcheck disable=SC2123  # Intentionally hide every jq executable for this case.
if (unset -f jq; PATH=/nonexistent; require_json_parser >/dev/null 2>&1); then
  fail "missing jq was accepted"
fi

EXPECTED_AWS_ACCOUNT_ID='123456789012'
TERRAFORM_MODE='empty'
terraform() {
  case "$TERRAFORM_MODE:$*" in
    'empty:'*' state list') return 0 ;;
    'correct:'*' state list') printf 'aws_ecr_repository.services["frontend"]\n' ;;
    'correct:'*' output -raw expected_aws_account_id') printf '123456789012\n' ;;
    'wrong:'*' state list') printf 'aws_ecr_repository.services["frontend"]\n' ;;
    'wrong:'*' output -raw expected_aws_account_id') printf '999999999999\n' ;;
    *) return 1 ;;
  esac
}
verify_terraform_state_account /mock/empty >/dev/null || fail "empty state was rejected"
TERRAFORM_MODE='correct'
verify_terraform_state_account /mock/correct >/dev/null || fail "expected state account was rejected"
TERRAFORM_MODE='wrong'
if verify_terraform_state_account /mock/wrong >/dev/null 2>&1; then
  fail "wrong state account was accepted"
fi

printf 'AWS identity and Terraform state account guards validated.\n'
