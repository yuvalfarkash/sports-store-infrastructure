data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_main_branch_subjects = [
    for repository in var.github_repositories :
    "repo:${var.github_organization}/${repository}:ref:refs/heads/main"
  ]
}

data "aws_iam_policy_document" "github_ecr_publisher_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_main_branch_subjects
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
