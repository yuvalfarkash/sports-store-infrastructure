data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
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
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # This org has GitHub's subject-claim customization on, which appends
      # numeric org/repo IDs to the sub claim
      # (repo:ORG@<org_id>/REPO@<repo_id>:ref:...) instead of the plain
      # repo:ORG/REPO:ref:... format. Match both so this doesn't silently
      # break again if that setting changes - verified the actual claim via
      # CloudTrail (Username field on the AssumeRoleWithWebIdentity event).
      values = [
        "repo:${var.github_organization}/sports-store-*:*",
        "repo:${var.github_organization}@*/sports-store-*:*",
      ]
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
