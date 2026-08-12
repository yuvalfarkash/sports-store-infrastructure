#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/aws-account-safety.sh
source "$TEST_ROOT/scripts/aws-account-safety.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

AWS_ACCOUNT='123456789012'
AWS_ARN='arn:aws:iam::123456789012:user/deploy-user'
AWS_FAILURE='false'
aws() {
  [[ "$AWS_FAILURE" == 'false' ]] || return 1
  case "$*" in
    *'--query Account'*) printf '%s\n' "$AWS_ACCOUNT" ;;
    *'--query Arn'*) printf '%s\n' "$AWS_ARN" ;;
    *) return 1 ;;
  esac
}
verify_expected_aws_identity >/dev/null || fail "expected account was rejected"

AWS_ACCOUNT='324621154117'
AWS_ARN='arn:aws:iam::324621154117:user/wrong'
if verify_expected_aws_identity >/dev/null 2>&1; then
  fail "wrong account was accepted"
fi

AWS_ACCOUNT='not-an-account'
AWS_ARN='not-an-arn'
if verify_expected_aws_identity >/dev/null 2>&1; then
  fail "malformed identity was accepted"
fi

AWS_FAILURE='true'
if verify_expected_aws_identity >/dev/null 2>&1; then
  fail "missing identity was accepted"
fi

EXPECTED_AWS_ACCOUNT_ID='123456789012'
TERRAFORM_MODE='empty'
terraform() {
  case "$TERRAFORM_MODE:$*" in
    'empty:'*' state list') return 0 ;;
    'correct:'*' state list') printf 'aws_ecr_repository.services["frontend"]\n' ;;
    'correct:'*' output -raw expected_aws_account_id') printf '123456789012\n' ;;
    'wrong:'*' state list') printf 'aws_ecr_repository.services["frontend"]\n' ;;
    'wrong:'*' output -raw expected_aws_account_id') printf '324621154117\n' ;;
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
