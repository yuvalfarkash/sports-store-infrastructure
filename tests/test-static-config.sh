#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -q 'targetRevision = "main"' terraform/automation.tf || fail "Argo CD no longer targets main"
grep -q 'name = "sports-store"' terraform/automation.tf || fail "namespace changed"

if grep -Rqi 'sports-store-gateway' terraform/ecr.tf terraform/iam-oidc.tf \
  terraform/automation.tf terraform/variables.tf terraform/terraform.tfvars.example deploy.sh; then
  fail "Gateway remains in a production image, publisher, updater, or dispatch configuration"
fi

if grep -Rqs 'aws_secretsmanager_secret_version' terraform --include='*.tf' \
  --exclude-dir=.terraform; then
  fail "Terraform must not manage an application secret version"
fi

[[ -f terraform/cloudfront/main.tf && -f terraform/cloudfront/versions.tf ]] ||
  fail "CloudFront must remain a separate Terraform root"

cloudfront_line="$(grep -n 'terraform -chdir="\$CLOUDFRONT_DIR" destroy' destroy.sh | cut -d: -f1)"
base_line="$(grep -n 'terraform -chdir="\$TERRAFORM_DIR" destroy' destroy.sh | cut -d: -f1)"
[[ -n "$cloudfront_line" && -n "$base_line" && "$cloudfront_line" -lt "$base_line" ]] ||
  fail "CloudFront destruction must precede base infrastructure destruction"

if git ls-files | grep -Eq '(^|/)[^/]+\.tfstate(\.|$)|(^|/)\.terraform/'; then
  fail "Terraform state or provider cache is tracked"
fi

printf 'Infrastructure static invariants validated.\n'
