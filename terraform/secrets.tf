locals {
  application_secret_name          = "sports-store/production/app"
  external_secrets_namespace       = "external-secrets"
  external_secrets_service_account = "external-secrets"
  external_secrets_role_name       = "${var.cluster_name}-external-secrets"
}

# Terraform owns only the secret container and metadata. The bootstrap script
# creates versions so secret values never enter Terraform configuration/state.
resource "aws_secretsmanager_secret" "application" {
  name        = local.application_secret_name
  description = "Sports Store production application credentials"

  # Course environments are frequently destroyed and recreated. Immediate
  # deletion prevents the deterministic name from being held by a scheduled
  # deletion, at the cost of making Terraform destroy non-recoverable.
  recovery_window_in_days = 0

  tags = local.common_tags
}

resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = local.external_secrets_namespace
  }

  depends_on = [module.eks]
}

data "aws_iam_policy_document" "external_secrets_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values = [
        "system:serviceaccount:${local.external_secrets_namespace}:${local.external_secrets_service_account}",
      ]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = local.external_secrets_role_name
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid = "ReadSportsStoreApplicationSecret"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [aws_secretsmanager_secret.application.arn]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "sports-store-read-application-secret"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}
