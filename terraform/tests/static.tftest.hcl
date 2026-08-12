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
