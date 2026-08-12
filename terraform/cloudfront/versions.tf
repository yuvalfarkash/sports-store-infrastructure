terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.42"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [local.expected_account_id]

  default_tags {
    tags = local.common_tags
  }
}

locals {
  aws_environment     = jsondecode(file("${path.module}/../../config/aws-environment.json"))
  expected_account_id = local.aws_environment.expected_account_id

  common_tags = {
    Project     = "sports-store"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}


data "aws_caller_identity" "current" {}

resource "terraform_data" "expected_aws_account" {
  input = data.aws_caller_identity.current.account_id

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == local.expected_account_id
      error_message = "AWS account safety check failed. Expected account ${local.expected_account_id}, actual account ${data.aws_caller_identity.current.account_id}. No deployment should continue."
    }
  }
}
