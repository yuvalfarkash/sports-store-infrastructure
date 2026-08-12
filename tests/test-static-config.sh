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
grep -q 'aquasecurity/trivy-action@a9c7b0f06e461e9d4b4d1711f154ee024b8d7ab8 # v0.36.0' .github/workflows/ci.yaml ||
  fail "Trivy Action is not pinned to the verified v0.36.0 commit"

oidc_provider_count="$(grep -RhsEc '^resource "aws_iam_openid_connect_provider" ' terraform --include='*.tf' --exclude-dir=.terraform | awk '{ total += $1 } END { print total + 0 }')"
[[ "$oidc_provider_count" -eq 1 ]] || fail "exactly one managed GitHub OIDC provider must be declared"
if grep -Rqs '^data "aws_iam_openid_connect_provider" ' terraform --include='*.tf' --exclude-dir=.terraform; then
  fail "GitHub OIDC must be managed rather than looked up as a prerequisite"
fi
grep -q 'url[[:space:]]*= "https://token.actions.githubusercontent.com"' terraform/iam-oidc.tf ||
  fail "managed GitHub OIDC provider URL is incorrect"
grep -q 'client_id_list[[:space:]]*= \["sts.amazonaws.com"\]' terraform/iam-oidc.tf ||
  fail "managed GitHub OIDC provider must use only the AWS STS audience"
grep -q 'identifiers = \[aws_iam_openid_connect_provider.github_actions.arn\]' terraform/iam-oidc.tf ||
  fail "publisher role trust does not reference the managed OIDC provider ARN"
grep -A 3 'variable = "token.actions.githubusercontent.com:aud"' terraform/iam-oidc.tf |
  grep -q 'values[[:space:]]*= \["sts.amazonaws.com"\]' || fail "OIDC audience condition is not restricted to AWS STS"
grep -q 'repo:${var.github_organization}/${repository}:ref:refs/heads/main' terraform/iam-oidc.tf || fail "OIDC main-branch subject is missing"
grep -Eq 'default[[:space:]]*= "sports-store-devops-team"' terraform/variables.tf || fail "OIDC organization trust changed"
for repository in \
  sports-store-frontend \
  sports-store-auth-service \
  sports-store-catalog-service \
  sports-store-cart-service \
  sports-store-order-service \
  sports-store-payment-service; do
  grep -q "\"$repository\"" terraform/variables.tf || fail "approved OIDC repository is missing: $repository"
done
oidc_trust="$(sed -n '1,/^resource "aws_iam_role" "github_ecr_publisher"/p' terraform/iam-oidc.tf)"
if grep -q 'StringLike' <<<"$oidc_trust" || grep -q '@\*' <<<"$oidc_trust" || grep -q '"\*"' <<<"$oidc_trust"; then
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
