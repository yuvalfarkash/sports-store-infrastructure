locals {
  github_static_site_oidc_subject = "repo:${var.github_organization}@${var.github_organization_id}/sports-store-frontend@${lookup(var.github_repository_ids, "sports-store-frontend", 0)}:ref:refs/heads/main"
  static_site_bucket_actions      = ["s3:GetBucketLocation", "s3:ListBucket"]
  static_site_object_actions      = ["s3:PutObject", "s3:DeleteObject"]
}

data "aws_iam_policy_document" "github_static_site_publisher_assume_role" {
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
      values   = [local.github_static_site_oidc_subject]
    }
  }
}

resource "aws_iam_role" "github_static_site_publisher" {
  name               = "sports-store-github-static-site-publisher"
  assume_role_policy = data.aws_iam_policy_document.github_static_site_publisher_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "github_static_site_publisher" {
  statement {
    sid       = "InspectStaticSiteBucket"
    actions   = local.static_site_bucket_actions
    resources = [aws_s3_bucket.static_site.arn]
  }

  statement {
    sid       = "PublishStaticSiteObjects"
    actions   = local.static_site_object_actions
    resources = ["${aws_s3_bucket.static_site.arn}/*"]
  }
}

resource "aws_iam_role_policy" "github_static_site_publisher" {
  name   = "sports-store-static-site-publish"
  role   = aws_iam_role.github_static_site_publisher.id
  policy = data.aws_iam_policy_document.github_static_site_publisher.json
}
