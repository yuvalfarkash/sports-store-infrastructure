resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = local.common_tags
}

locals {
  github_backend_repositories = [
    "sports-store-auth-service",
    "sports-store-catalog-service",
    "sports-store-cart-service",
    "sports-store-order-service",
    "sports-store-payment-service",
  ]

  github_oidc_subjects = [
    for repository in local.github_backend_repositories :
    "repo:${var.github_organization}@${var.github_organization_id}/${repository}@${lookup(var.github_repository_ids, repository, 0)}:ref:refs/heads/main"
  ]
}

data "aws_iam_policy_document" "github_ecr_publisher_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_oidc_subjects
    }
  }
}

resource "aws_iam_role" "github_ecr_publisher" {
  name               = "sports-store-github-ecr-publisher"
  assume_role_policy = data.aws_iam_policy_document.github_ecr_publisher_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "github_ecr_publisher" {
  statement {
    sid       = "ECRAuthentication"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PublishApplicationImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = values(aws_ecr_repository.services)[*].arn
  }
}

resource "aws_iam_role_policy" "github_ecr_publisher" {
  name   = "sports-store-ecr-publish"
  role   = aws_iam_role.github_ecr_publisher.id
  policy = data.aws_iam_policy_document.github_ecr_publisher.json
}
