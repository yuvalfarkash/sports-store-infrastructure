#!/usr/bin/env bash

AWS_ENVIRONMENT_FILE="${AWS_ENVIRONMENT_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../config" && pwd)/aws-environment.json}"

json_string_value() {
  local json="$1"
  local key="$2"
  local value

  value="$(printf '%s' "$json" | tr -d '\r\n' | sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p")"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

load_aws_environment() {
  local configuration

  [[ -r "$AWS_ENVIRONMENT_FILE" ]] || {
    printf 'ERROR: AWS environment configuration is unreadable: %s\n' "$AWS_ENVIRONMENT_FILE" >&2
    return 1
  }
  configuration="$(<"$AWS_ENVIRONMENT_FILE")"
  EXPECTED_AWS_ACCOUNT_ID="$(json_string_value "$configuration" expected_account_id)" || return 1
  EXPECTED_AWS_REGION="$(json_string_value "$configuration" aws_region)" || return 1
  DEPLOYMENT_PRINCIPAL_ARN="$(json_string_value "$configuration" deployment_principal_arn)" || return 1

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
  local actual_account caller_arn

  load_aws_environment || return 1
  actual_account="$(aws sts get-caller-identity --query Account --output text)" || {
    printf 'ERROR: unable to determine active AWS identity; expected account %s. No deployment should continue.\n' \
      "$EXPECTED_AWS_ACCOUNT_ID" >&2
    return 1
  }
  caller_arn="$(aws sts get-caller-identity --query Arn --output text)" || {
    printf 'ERROR: unable to determine caller ARN; expected account %s. No deployment should continue.\n' \
      "$EXPECTED_AWS_ACCOUNT_ID" >&2
    return 1
  }

  printf 'Expected AWS account: %s\n' "$EXPECTED_AWS_ACCOUNT_ID"
  printf 'Actual AWS account: %s\n' "$actual_account"
  printf 'Caller ARN: %s\n' "$caller_arn"

  if [[ ! "$actual_account" =~ ^[0-9]{12}$ || ! "$caller_arn" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role|assumed-role)/.+$ ]]; then
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
