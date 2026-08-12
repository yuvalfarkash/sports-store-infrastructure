#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -q 'targetRevision = "main"' terraform/automation.tf || fail "Argo CD no longer targets main"
grep -q 'name = "sports-store"' terraform/automation.tf || fail "namespace changed"
grep -q 'targetRevision = "main"' terraform/automation.tf || fail "Argo CD no longer targets main"
grep -q 'global.applicationImageRegistry' terraform/automation.tf || fail "Argo CD no longer injects the account-derived registry"
grep -q 'deployment_principal_arn' config/aws-environment.json || fail "authoritative deployment principal is missing"
grep -q '\[local.deployment_principal\]' terraform/eks-iam.tf || fail "deployment principal is not granted EKS access"
grep -q 'repo:${var.github_organization}/${repository}:ref:refs/heads/main' terraform/iam-oidc.tf || fail "OIDC main-branch subject is missing"
if grep -q 'StringLike' terraform/iam-oidc.tf || grep -q '@\*' terraform/iam-oidc.tf; then
  fail "OIDC trust contains wildcard subject matching"
fi
grep -q -- '--event push' deploy.sh || fail "deploy does not preserve the main-push publication gate"
if grep -q 'gh workflow run' deploy.sh; then
  fail "deploy uses workflow_dispatch, which cannot publish application images"
fi

old_account_id="324621""154117"
if git grep -n "$old_account_id" -- ':!tests/test-account-safety.sh' ':!terraform/tests/*.tftest.hcl' ':!terraform/cloudfront/tests/*.tftest.hcl'; then
  fail "Yuval account remains in active tracked configuration"
fi

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
