mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
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

run "production_inventory" {
  command = plan

  plan_options {
    target = [aws_ecr_repository.services]
  }

  assert {
    condition     = length(local.microservices) == 6 && !contains(local.microservices, "sports-store-gateway")
    error_message = "Production ECR inventory must contain six images and exclude Gateway."
  }

}
