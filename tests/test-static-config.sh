#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

terraform_resource_block() {
  local resource_type="$1"
  local resource_name="$2"
  local file="$3"

  awk -v declaration="resource \"$resource_type\" \"$resource_name\"" '
    index($0, declaration) == 1 { printing = 1 }
    printing {
      print
      opens = gsub(/{/, "{")
      closes = gsub(/}/, "}")
      depth += opens - closes
      if (depth == 0) exit
    }
  ' "$file"
}

grep -q 'targetRevision = "main"' terraform/automation.tf || fail "Argo CD no longer targets main"
grep -q 'name = "sports-store"' terraform/automation.tf || fail "namespace changed"
grep -q 'targetRevision = "main"' terraform/automation.tf || fail "Argo CD no longer targets main"
grep -q 'global.applicationImageRegistry' terraform/automation.tf || fail "Argo CD no longer injects the account-derived registry"
for application in sports-store-monitoring sports-store-loki sports-store-alloy sports-store; do
  grep -q "name[[:space:]]*= \"$application\"" terraform/automation.tf ||
    fail "Argo CD Application is missing: $application"
done
grep -q 'repoURL[[:space:]]*= "https://grafana-community.github.io/helm-charts"' terraform/automation.tf ||
  fail "Loki does not use the official Grafana Community chart repository"
grep -q 'targetRevision[[:space:]]*= "18.5.0"' terraform/automation.tf || fail "Loki chart is not pinned"
grep -q 'repoURL[[:space:]]*= "https://grafana.github.io/helm-charts"' terraform/automation.tf ||
  fail "Alloy does not use the official Grafana chart repository"
grep -q 'targetRevision[[:space:]]*= "1.11.0"' terraform/automation.tf || fail "Alloy chart is not pinned"
grep -q '\$values/logging/loki-values.yaml' terraform/automation.tf || fail "Loki values source is missing"
grep -q '\$values/logging/alloy-values.yaml' terraform/automation.tf || fail "Alloy values source is missing"
[[ "$(grep -c 'targetRevision = "main"' terraform/automation.tf)" -eq 5 ]] ||
  fail "all five deployment Git sources must target main"
forbidden_revision="the operator""Branch"
if grep -q "targetRevision[[:space:]]*= \"$forbidden_revision\"" terraform/automation.tf; then
  fail "Argo CD must never target the development branch"
fi
for wave in 0 1 2 3; do
  grep -q '"argocd.argoproj.io/sync-wave" = "'"$wave"'"' terraform/automation.tf ||
    fail "Argo CD sync wave is missing: $wave"
done
grep -A 90 'resource "kubectl_manifest" "argocd_loki_app"' terraform/automation.tf |
  grep -q 'kubectl_manifest.argocd_monitoring_app' || fail "Loki must depend on monitoring"
grep -A 90 'resource "kubectl_manifest" "argocd_alloy_app"' terraform/automation.tf |
  grep -q 'kubectl_manifest.argocd_loki_app' || fail "Alloy must depend on Loki"
grep -q 'deployment_principal_arn' config/aws-environment.json || fail "authoritative deployment principal is missing"
grep -q 'enable_cluster_creator_admin_permissions = true' terraform/eks.tf ||
  fail "EKS module no longer owns cluster-creator administration"
grep -q 'if arn != local.deployment_principal' terraform/eks-iam.tf ||
  fail "standalone EKS access entries do not filter the deployment principal"
if grep -q '\[local.deployment_principal\]' terraform/eks-iam.tf; then
  fail "deployment principal is still managed by the standalone EKS access-entry resource"
fi
grep -q 'for_each = local.approved_eks_principal_arns' terraform/eks-iam.tf ||
  fail "additional EKS access entries do not use the filtered, deduplicated principal set"
grep -A 18 'resource "aws_eks_access_policy_association" "approved_principals_admin"' terraform/eks-iam.tf |
  grep -q 'AmazonEKSClusterAdminPolicy' || fail "additional EKS principals lost cluster-admin association"

for release in external_secrets argocd metrics_server; do
  terraform_resource_block helm_release "$release" terraform/helm.tf |
    grep -q 'helm_release.aws_load_balancer_controller' ||
    fail "$release can start before the AWS Load Balancer Controller is ready"
done
terraform_resource_block helm_release argocd_image_updater terraform/helm.tf |
  grep -q 'helm_release.argocd' || fail "Argo CD Image Updater no longer waits for Argo CD"
[[ "$(grep -c 'wait[[:space:]]*= true' terraform/helm.tf)" -eq 5 ]] ||
  fail "every Terraform-managed Helm release must explicitly wait for readiness"
[[ "$(grep -c 'timeout[[:space:]]*= 600' terraform/helm.tf)" -eq 5 ]] ||
  fail "every Terraform-managed Helm release must use the bounded timeout"
if grep -Eq '(^|[[:space:]])(sleep|local-exec|remote-exec|provisioner|null_resource)([[:space:]]|=|$)' terraform/helm.tf; then
  fail "Helm ordering must not use sleeps, provisioners, or null resources"
fi
grep -q 'aquasecurity/trivy-action@a9c7b0f06e461e9d4b4d1711f154ee024b8d7ab8  # v0.36.0' .github/workflows/ci.yaml ||
  fail "Trivy Action is not pinned to the verified v0.36.0 commit"

grep -q 'eks_managed_node_groups = local.managed_node_groups' terraform/eks.tf ||
  fail "EKS must use the asserted single managed node-group configuration"
grep -q 'subnet_ids[[:space:]]*= module.vpc.private_subnets' terraform/eks.tf ||
  fail "the managed node group must remain in private subnets"
grep -q 'ENABLE_PREFIX_DELEGATION = "false"' terraform/eks.tf ||
  fail "VPC CNI prefix delegation must remain disabled"
if grep -Rqs 'maxPods:' terraform --include='*.tf' --exclude-dir=.terraform; then
  fail "unsupported custom kubelet maxPods override remains configured"
fi
if grep -RqiE 'capacity_type[[:space:]]*=[[:space:]]*"SPOT"|"cluster-autoscaler"|"karpenter"|cluster_autoscaler' terraform \
  --include='*.tf' --exclude-dir=.terraform; then
  fail "Spot capacity or an automatic node scaler must not be configured"
fi
grep -q 'aws-ebs-csi-driver' terraform/eks.tf || fail "EBS CSI add-on is missing"

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
grep -q 'repo:${var.github_organization}@${var.github_organization_id}/${repository}@${lookup(var.github_repository_ids, repository, 0)}:ref:refs/heads/main' terraform/iam-oidc.tf ||
  fail "immutable backend OIDC main-branch subject is missing"
grep -Eq 'default[[:space:]]*= "sports-store-devops-team"' terraform/variables.tf || fail "OIDC organization trust changed"
grep -Eq 'default[[:space:]]*= 311871744' terraform/variables.tf || fail "immutable GitHub organization ID changed"
for repository_identity in \
  'sports-store-frontend[[:space:]]*=[[:space:]]*1319569364' \
  'sports-store-auth-service[[:space:]]*=[[:space:]]*1319569433' \
  'sports-store-catalog-service[[:space:]]*=[[:space:]]*1319569475' \
  'sports-store-cart-service[[:space:]]*=[[:space:]]*1319569543' \
  'sports-store-order-service[[:space:]]*=[[:space:]]*1319569596' \
  'sports-store-payment-service[[:space:]]*=[[:space:]]*1319569661'; do
  grep -Eq "$repository_identity" terraform/variables.tf || fail "approved immutable OIDC repository identity is missing: $repository_identity"
done
grep -q 'repo:${var.github_organization}@${var.github_organization_id}/sports-store-frontend@${lookup(var.github_repository_ids, "sports-store-frontend", 0)}:ref:refs/heads/main' terraform/static-publication-iam.tf ||
  fail "immutable frontend static publication trust is not restricted to main"
grep -q 'length(distinct(values(var.github_repository_ids))) == length(var.github_repository_ids)' terraform/variables.tf ||
  fail "duplicate immutable GitHub repository IDs are not rejected"
grep -q 'id > 0 && floor(id) == id' terraform/variables.tf ||
  fail "non-positive or non-integer GitHub repository IDs are not rejected"
if grep -RqsE 'repo:sports-store-devops-team/(sports-store-(frontend|auth-service|catalog-service|cart-service|order-service|payment-service))' terraform \
  --include='*.tf' --include='*.tftest.hcl' --exclude-dir=.terraform; then
  fail "legacy name-only GitHub OIDC subject remains"
fi
grep -q 'resource "aws_s3_bucket" "static_site"' terraform/static-site.tf || fail "private static bucket is missing"
grep -q 'force_destroy = true' terraform/static-site.tf || fail "static bucket must be removable with course teardown"
for control in block_public_acls block_public_policy ignore_public_acls restrict_public_buckets; do
  grep -q "${control}[[:space:]]*= true" terraform/static-site.tf || fail "missing S3 public access block: $control"
done
grep -q 'origin_access_control_origin_type = "s3"' terraform/cloudfront/main.tf || fail "CloudFront S3 OAC is missing"
grep -q 'signing_behavior[[:space:]]*= "always"' terraform/cloudfront/main.tf || fail "CloudFront OAC signing is not mandatory"
grep -q 'variable = "AWS:SourceArn"' terraform/cloudfront/main.tf || fail "CloudFront bucket policy lacks SourceArn restriction"
grep -A 3 'variable = "AWS:SourceArn"' terraform/cloudfront/main.tf |
  grep -q 'values[[:space:]]*= \[aws_cloudfront_distribution.sports_store\[0\].arn\]' ||
  fail "CloudFront bucket policy does not use the exact managed distribution ARN"
grep -A 12 'resource "aws_s3_bucket_policy" "cloudfront_static_site"' terraform/cloudfront/main.tf |
  grep -q 'policy = data.aws_iam_policy_document.cloudfront_static_site\[0\].json' ||
  fail "S3 bucket policy is not sourced from the restricted CloudFront policy document"
grep -q 'path_pattern[[:space:]]*= "/api/\*"' terraform/cloudfront/main.tf || fail "API behavior missing"
grep -q 'path_pattern[[:space:]]*= "/assets/\*"' terraform/cloudfront/main.tf || fail "asset behavior missing"
if grep -Rqs 'website_endpoint\|website {' terraform --include='*.tf' --exclude-dir=.terraform; then
  fail "S3 website hosting must not be configured"
fi
oidc_trust="$(sed -n '1,/^resource "aws_iam_role" "github_ecr_publisher"/p' terraform/iam-oidc.tf)"
if grep -q 'StringLike' <<<"$oidc_trust" || grep -q '@\*' <<<"$oidc_trust" || grep -q '"\*"' <<<"$oidc_trust"; then
  fail "OIDC trust contains wildcard subject matching"
fi
grep -q 'name[[:space:]]*= "sports-store-github-ecr-publisher"' terraform/iam-oidc.tf ||
  fail "existing ECR publisher role name changed"
grep -q 'name[[:space:]]*= "sports-store-github-static-site-publisher"' terraform/static-publication-iam.tf ||
  fail "existing frontend publisher role name changed"
grep -q 'gh workflow run ci.yaml' deploy.sh || fail "deploy does not dispatch ci.yaml explicitly"
grep -q -- '--ref main' deploy.sh || fail "deploy does not pin workflow dispatches to main"
grep -q -- 'expected_sha=' deploy.sh || fail "deploy does not send the expected main SHA"
grep -q -- 'deployment_id=' deploy.sh || fail "deploy does not send a correlation identifier"
grep -q 'git/ref/heads/main' deploy.sh || fail "deploy does not query the exact remote main ref"
grep -q 'workflow_dispatch' deploy.sh || fail "deploy does not correlate manual workflow runs"
if grep -q 'gh run rerun' deploy.sh; then
  fail "deploy can still rerun a historical workflow"
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
