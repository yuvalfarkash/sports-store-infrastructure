#!/usr/bin/env bash

AWS_ENVIRONMENT_FILE="${AWS_ENVIRONMENT_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../config" && pwd)/aws-environment.json}"

require_json_parser() {
  command -v jq >/dev/null 2>&1 || {
    printf 'ERROR: jq is required to validate AWS identity JSON safely. No deployment should continue.\n' >&2
    return 1
  }
}

load_aws_environment() {
  local configuration

  require_json_parser || return 1
  [[ -r "$AWS_ENVIRONMENT_FILE" ]] || {
    printf 'ERROR: AWS environment configuration is unreadable: %s\n' "$AWS_ENVIRONMENT_FILE" >&2
    return 1
  }
  configuration="$(<"$AWS_ENVIRONMENT_FILE")"
  EXPECTED_AWS_ACCOUNT_ID="$(jq -er '.expected_account_id | select(type == "string" and length > 0)' <<<"$configuration")" || return 1
  EXPECTED_AWS_REGION="$(jq -er '.aws_region | select(type == "string" and length > 0)' <<<"$configuration")" || return 1
  DEPLOYMENT_PRINCIPAL_ARN="$(jq -er '.deployment_principal_arn | select(type == "string" and length > 0)' <<<"$configuration")" || return 1

  [[ "$EXPECTED_AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || {
    printf 'ERROR: configured expected AWS account ID is malformed.\n' >&2
    return 1
  }
  [[ -n "$EXPECTED_AWS_REGION" && "$DEPLOYMENT_PRINCIPAL_ARN" == arn:aws:iam::${EXPECTED_AWS_ACCOUNT_ID}:* ]] || {
    printf 'ERROR: AWS environment configuration is inconsistent.\n' >&2
    return 1
  }
}

verify_expected_aws_identity() {
  local identity_json actual_account caller_arn iam_identity_pattern assumed_role_pattern

  load_aws_environment || return 1
  identity_json="$(aws sts get-caller-identity --output json)" || {
    printf 'ERROR: unable to determine active AWS identity; expected account %s. No deployment should continue.\n' \
      "$EXPECTED_AWS_ACCOUNT_ID" >&2
    return 1
  }
  actual_account="$(jq -er '.Account | select(type == "string" and length > 0)' <<<"$identity_json")" || {
    printf 'ERROR: AWS identity response has no valid Account field; expected account %s. No deployment should continue.\n' \
      "$EXPECTED_AWS_ACCOUNT_ID" >&2
    return 1
  }
  caller_arn="$(jq -er '.Arn | select(type == "string" and length > 0)' <<<"$identity_json")" || {
    printf 'ERROR: AWS identity response has no valid Arn field; expected account %s. No deployment should continue.\n' \
      "$EXPECTED_AWS_ACCOUNT_ID" >&2
    return 1
  }

  printf 'Expected AWS account: %s\n' "$EXPECTED_AWS_ACCOUNT_ID"
  printf 'Actual AWS account: %s\n' "$actual_account"
  printf 'Caller ARN: %s\n' "$caller_arn"

  iam_identity_pattern="^arn:(aws|aws-us-gov|aws-cn):iam::${actual_account}:(user|role)/[A-Za-z0-9+=,.@_-]+(/[A-Za-z0-9+=,.@_-]+)*$"
  assumed_role_pattern="^arn:(aws|aws-us-gov|aws-cn):sts::${actual_account}:assumed-role/[A-Za-z0-9+=,.@_-]+/[A-Za-z0-9+=,.@_-]+$"
  if [[ ! "$actual_account" =~ ^[0-9]{12}$ ]] ||
    [[ ! "$caller_arn" =~ $iam_identity_pattern && ! "$caller_arn" =~ $assumed_role_pattern ]]; then
    printf 'ERROR: AWS identity response is malformed. No deployment should continue.\n' >&2
    return 1
  fi
  if [[ "$actual_account" != "$EXPECTED_AWS_ACCOUNT_ID" ]]; then
    printf 'ERROR: AWS account mismatch. Expected %s, actual %s. No deployment should continue.\n' \
      "$EXPECTED_AWS_ACCOUNT_ID" "$actual_account" >&2
    return 1
  fi
}

verify_terraform_state_account() {
  local terraform_directory="$1"
  local state_resources state_account

  state_resources="$(terraform -chdir="$terraform_directory" state list 2>&1)" || {
    if [[ "$state_resources" == *"No state file"* ]]; then
      printf 'Terraform state is empty: %s\n' "$terraform_directory"
      return 0
    fi
    printf 'ERROR: unable to inspect Terraform state: %s\n' "$terraform_directory" >&2
    return 1
  }
  if [[ -z "$state_resources" ]]; then
    printf 'Terraform state is empty: %s\n' "$terraform_directory"
    return 0
  fi

  state_account="$(terraform -chdir="$terraform_directory" output -raw expected_aws_account_id 2>/dev/null)" || {
    printf 'ERROR: non-empty Terraform state in %s has no expected-account output; refusing mutation.\n' \
      "$terraform_directory" >&2
    return 1
  }
  if [[ "$state_account" != "$EXPECTED_AWS_ACCOUNT_ID" ]]; then
    printf 'ERROR: Terraform state account mismatch in %s. Expected %s, state reports %s.\n' \
      "$terraform_directory" "$EXPECTED_AWS_ACCOUNT_ID" "$state_account" >&2
    return 1
  fi
  printf 'Terraform state account verified: %s (%s)\n' "$terraform_directory" "$state_account"
}
