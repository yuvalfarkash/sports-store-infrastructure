mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/deploy-user"
      user_id    = "AIDATESTUSER"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-central-1a", "eu-central-1b"]
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}
mock_provider "tls" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}

run "expected_account_configuration" {
  command = plan

  plan_options {
    target = [
      terraform_data.expected_aws_account,
      aws_ecr_repository.services,
      aws_iam_openid_connect_provider.github_actions,
      data.aws_iam_policy_document.github_ecr_publisher_assume_role,
    ]
  }

  assert {
    condition     = local.account_id == "123456789012" && local.application_image_registry == "123456789012.dkr.ecr.eu-central-1.amazonaws.com"
    error_message = "The ECR registry must be derived from the authenticated the operator account and configured region."
  }

  assert {
    condition     = length(local.microservices) == 6 && !contains(local.microservices, "sports-store-gateway")
    error_message = "Production ECR inventory must contain six images and exclude Gateway."
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github_actions.url == "https://token.actions.githubusercontent.com"
    error_message = "The managed GitHub Actions OIDC provider must use the exact GitHub token URL."
  }

  assert {
    condition     = toset(aws_iam_openid_connect_provider.github_actions.client_id_list) == toset(["sts.amazonaws.com"])
    error_message = "The managed GitHub Actions OIDC provider must have only the AWS STS audience."
  }

  assert {
    condition     = var.github_organization == "sports-store-devops-team"
    error_message = "GitHub publishing trust must remain restricted to the Sports Store organization."
  }

  assert {
    condition = toset(local.github_oidc_subjects) == toset([
      "repo:sports-store-devops-team/sports-store-frontend:ref:refs/heads/main",
      "repo:sports-store-devops-team/sports-store-auth-service:ref:refs/heads/main",
      "repo:sports-store-devops-team/sports-store-catalog-service:ref:refs/heads/main",
      "repo:sports-store-devops-team/sports-store-cart-service:ref:refs/heads/main",
      "repo:sports-store-devops-team/sports-store-order-service:ref:refs/heads/main",
      "repo:sports-store-devops-team/sports-store-payment-service:ref:refs/heads/main",
    ])
    error_message = "OIDC subjects must be exactly the six approved application repositories on main."
  }

  assert {
    condition = (
      length(local.github_oidc_subjects) == 6 &&
      alltrue([for subject in local.github_oidc_subjects : endswith(subject, ":ref:refs/heads/main")]) &&
      alltrue([for subject in local.github_oidc_subjects : !strcontains(subject, "*")]) &&
      alltrue([for subject in local.github_oidc_subjects : !strcontains(subject, "sports-store-gateway")])
    )
    error_message = "OIDC trust must not include Gateway, wildcard identities, or non-main refs."
  }

}

run "wrong_account_rejected" {
  command = plan

  plan_options {
    target = [terraform_data.expected_aws_account]
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "324621154117"
      arn        = "arn:aws:iam::324621154117:user/wrong-account"
      user_id    = "AIDAWRONGACCOUNT"
    }
  }

  expect_failures = [terraform_data.expected_aws_account]

}
