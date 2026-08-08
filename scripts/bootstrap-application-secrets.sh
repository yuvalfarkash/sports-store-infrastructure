#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  printf '%s\n' \
    'Usage: bootstrap-application-secrets.sh [--check | --rotate]' \
    '' \
    '  --check   Verify identity, secret metadata, and whether AWSCURRENT exists.' \
    '  --rotate  Explicitly replace an existing AWSCURRENT secret version.' \
    '' \
    'Optional environment variables:' \
    '  AWS_REGION or AWS_DEFAULT_REGION  Override the Terraform aws_region output.' \
    '  SPORTS_STORE_SECRET_ID            Override the application_secret_name output.'
}

mode='write'
rotate='false'

while (($# > 0)); do
  case "$1" in
    --check)
      if [[ "$rotate" == 'true' ]]; then
        printf 'Error: --check and --rotate cannot be combined.\n' >&2
        exit 2
      fi
      mode='check'
      ;;
    --rotate)
      if [[ "$mode" == 'check' ]]; then
        printf 'Error: --check and --rotate cannot be combined.\n' >&2
        exit 2
      fi
      rotate='true'
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

for tool in aws dirname; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Error: required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

if [[ "$mode" == 'write' ]]; then
  for tool in openssl mktemp chmod rm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'Error: required tool not found: %s\n' "$tool" >&2
      exit 1
    fi
  done
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$(cd -- "$script_dir/../terraform" && pwd)"

aws_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
secret_id="${SPORTS_STORE_SECRET_ID:-}"

if [[ -z "$aws_region" || -z "$secret_id" ]]; then
  if ! command -v terraform >/dev/null 2>&1; then
    printf 'Error: terraform is required when region or secret ID overrides are not set.\n' >&2
    exit 1
  fi
fi

if [[ -z "$aws_region" ]]; then
  aws_region="$(terraform -chdir="$terraform_dir" output -raw aws_region 2>/dev/null)" || {
    printf 'Error: could not read aws_region from Terraform output.\n' >&2
    exit 1
  }
fi

if [[ -z "$secret_id" ]]; then
  secret_id="$(terraform -chdir="$terraform_dir" output -raw application_secret_name 2>/dev/null)" || {
    printf 'Error: could not read application_secret_name from Terraform output.\n' >&2
    exit 1
  }
fi

if [[ -z "$aws_region" || -z "$secret_id" ]]; then
  printf 'Error: AWS region and secret identifier must not be empty.\n' >&2
  exit 1
fi

identity="$(aws sts get-caller-identity \
  --region "$aws_region" \
  --query '[Account,Arn]' \
  --output text)" || {
  printf 'Error: unable to verify the active AWS identity.\n' >&2
  exit 1
}
read -r account_id caller_arn <<<"$identity"

secret_name="$(aws secretsmanager describe-secret \
  --secret-id "$secret_id" \
  --region "$aws_region" \
  --query 'Name' \
  --output text)" || {
  printf 'Error: unable to describe the application secret container. Run Terraform apply first.\n' >&2
  exit 1
}

current_version="$(aws secretsmanager list-secret-version-ids \
  --secret-id "$secret_id" \
  --region "$aws_region" \
  --include-deprecated \
  --query "Versions[?contains(VersionStages, 'AWSCURRENT')].VersionId | [0]" \
  --output text)" || {
  printf 'Error: unable to inspect application secret versions.\n' >&2
  exit 1
}

has_current='true'
if [[ -z "$current_version" || "$current_version" == 'None' || "$current_version" == 'null' ]]; then
  has_current='false'
fi

printf 'AWS account: %s\n' "$account_id"
printf 'Caller ARN: %s\n' "$caller_arn"
printf 'AWS region: %s\n' "$aws_region"
printf 'Secret name: %s\n' "$secret_name"

if [[ "$mode" == 'check' ]]; then
  if [[ "$has_current" == 'true' ]]; then
    printf 'Current version: present\n'
  else
    printf 'Current version: absent\n'
  fi
  exit 0
fi

if [[ "$has_current" == 'true' && "$rotate" != 'true' ]]; then
  printf 'Error: an AWSCURRENT version already exists; refusing to overwrite it.\n' >&2
  printf 'Use --check for a read-only check or --rotate for an explicit rotation.\n' >&2
  exit 1
fi

if [[ "$rotate" == 'true' ]]; then
  printf 'Operation: rotate the current MongoDB password and JWT secret.\n'
  printf 'Warning: MongoDB rotation requires a coordinated database procedure; changing only this secret can break authentication.\n'
else
  printf 'Operation: create the first application secret version.\n'
fi

printf "Type 'yes' to write a new secret version: "
IFS= read -r confirmation
if [[ "$confirmation" != 'yes' ]]; then
  printf 'Cancelled; no secret version was written.\n'
  exit 1
fi

secret_file=''
cleanup() {
  if [[ -n "${secret_file:-}" && -f "$secret_file" ]]; then
    rm -f -- "$secret_file"
  fi
}
trap cleanup EXIT HUP INT TERM
secret_file="$(mktemp "${TMPDIR:-/tmp}/sports-store-app-secrets.XXXXXX")"
chmod 600 "$secret_file"

# Hex is alphanumeric and carries four bits of entropy per character. The
# MongoDB password is therefore URI-safe without encoding, while both values
# remain cryptographically strong.
mongodb_root_password="$(openssl rand -hex 32)"
jwt_secret="$(openssl rand -hex 64)"

# printf is a shell builtin, so generated values are not exposed in a child
# process argument list. The file is protected by umask/chmod and the trap.
printf '{"MONGODB_ROOT_PASSWORD":"%s","JWT_SECRET":"%s"}\n' \
  "$mongodb_root_password" "$jwt_secret" >"$secret_file"

aws secretsmanager put-secret-value \
  --secret-id "$secret_id" \
  --region "$aws_region" \
  --secret-string "file://$secret_file" \
  --query 'ARN' \
  --output text >/dev/null

unset mongodb_root_password jwt_secret
printf 'A new AWS Secrets Manager version was stored without displaying its values.\n'
printf '%s\n' \
  'Safe verification commands:' \
  '  bash scripts/bootstrap-application-secrets.sh --check' \
  '  kubectl get secretstore,externalsecret -n sports-store' \
  '  kubectl wait --for=condition=Ready externalsecret/app-secrets -n sports-store --timeout=120s' \
  "  kubectl get secret app-secrets -n sports-store -o go-template='{{range \$key, \$_ := .data}}{{printf \"%s\\n\" \$key}}{{end}}'"
