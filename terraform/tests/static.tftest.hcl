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
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:user/deploy-user"
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
      aws_s3_bucket.static_site,
      aws_s3_bucket_public_access_block.static_site,
      aws_s3_bucket_ownership_controls.static_site,
      aws_s3_bucket_server_side_encryption_configuration.static_site,
      aws_iam_role.github_static_site_publisher,
      aws_iam_role.github_ecr_publisher,
      data.aws_iam_policy_document.github_static_site_publisher,
      data.aws_iam_policy_document.github_static_site_publisher_assume_role,
      aws_iam_openid_connect_provider.github_actions,
      data.aws_iam_policy_document.github_ecr_publisher_assume_role,
    ]
  }

  assert {
    condition     = local.account_id == "123456789012" && local.application_image_registry == "123456789012.dkr.ecr.eu-central-1.amazonaws.com"
    error_message = "The ECR registry must be derived from the authenticated account and configured region."
  }

  assert {
    condition     = length(local.microservices) == 5 && !contains(local.microservices, "sports-store-gateway") && !contains(local.microservices, "sports-store-frontend")
    error_message = "Production ECR inventory must contain only the five backend images."
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
    condition = (
      var.github_organization == "yuvalfarkash" &&
      var.github_organization_id == 78908574 &&
      var.github_repository_ids == tomap({
        sports-store-frontend        = 1349844546
        sports-store-auth-service    = 1349844338
        sports-store-catalog-service = 1349844250
        sports-store-cart-service    = 1349844165
        sports-store-order-service   = 1349844068
        sports-store-payment-service = 1349843991
      })
    )
    error_message = "GitHub publishing trust must use the exact reviewed organization and repository identities."
  }

  assert {
    condition = toset(local.github_oidc_subjects) == toset([
      "repo:yuvalfarkash@78908574/sports-store-auth-service@1349844338:ref:refs/heads/main",
      "repo:yuvalfarkash@78908574/sports-store-catalog-service@1349844250:ref:refs/heads/main",
      "repo:yuvalfarkash@78908574/sports-store-cart-service@1349844165:ref:refs/heads/main",
      "repo:yuvalfarkash@78908574/sports-store-order-service@1349844068:ref:refs/heads/main",
      "repo:yuvalfarkash@78908574/sports-store-payment-service@1349843991:ref:refs/heads/main",
    ])
    error_message = "ECR OIDC subjects must be exactly the five approved backend repositories on main."
  }

  assert {
    condition = (
      length(local.github_oidc_subjects) == 5 &&
      alltrue([for subject in local.github_oidc_subjects : endswith(subject, ":ref:refs/heads/main")]) &&
      alltrue([for subject in local.github_oidc_subjects : can(regex("^repo:yuvalfarkash@78908574/sports-store-[a-z-]+@[1-9][0-9]*:ref:refs/heads/main$", subject))]) &&
      alltrue([for subject in local.github_oidc_subjects : !strcontains(subject, "*")]) &&
      alltrue([for subject in local.github_oidc_subjects : !strcontains(subject, "sports-store-gateway")]) &&
      alltrue([for subject in local.github_oidc_subjects : !strcontains(subject, "repo:yuvalfarkash/")])
    )
    error_message = "OIDC trust must not include Gateway, wildcard identities, or non-main refs."
  }

  assert {
    condition = (
      aws_s3_bucket.static_site.bucket == "sports-store-static-123456789012-eu-central-1" &&
      aws_s3_bucket.static_site.force_destroy &&
      one(aws_s3_bucket_ownership_controls.static_site.rule).object_ownership == "BucketOwnerEnforced" &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.static_site.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    )
    error_message = "The static-site bucket must be deterministic, force-destroyable, bucket-owner enforced, and SSE-S3 encrypted."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.static_site.block_public_acls &&
      aws_s3_bucket_public_access_block.static_site.block_public_policy &&
      aws_s3_bucket_public_access_block.static_site.ignore_public_acls &&
      aws_s3_bucket_public_access_block.static_site.restrict_public_buckets
    )
    error_message = "All four static-site public access block controls must remain enabled."
  }

  assert {
    condition = (
      local.github_static_site_oidc_subject == "repo:yuvalfarkash@78908574/sports-store-frontend@1349844546:ref:refs/heads/main" &&
      toset(local.static_site_bucket_actions) == toset(["s3:GetBucketLocation", "s3:ListBucket"]) &&
      toset(local.static_site_object_actions) == toset(["s3:PutObject", "s3:DeleteObject"])
    )
    error_message = "The frontend publisher must trust only frontend/main and have only exact bucket publication permissions."
  }

  assert {
    condition = (
      aws_iam_role.github_ecr_publisher.name == "sports-store-github-ecr-publisher" &&
      aws_iam_role.github_static_site_publisher.name == "sports-store-github-static-site-publisher"
    )
    error_message = "Existing publisher role identities and managed assume-role policy wiring must remain unchanged."
  }

}

run "wrong_github_organization_id_is_rejected" {
  command = plan

  variables {
    github_organization_id = 311871745
  }

  expect_failures = [var.github_organization_id]
}

run "missing_github_repository_id_is_rejected" {
  command = plan

  variables {
    github_repository_ids = {
      sports-store-frontend        = 1349844546
      sports-store-auth-service    = 1349844338
      sports-store-catalog-service = 1349844250
      sports-store-cart-service    = 1349844165
      sports-store-order-service   = 1349844068
    }
  }

  expect_failures = [var.github_repository_ids]
}

run "extra_github_repository_id_is_rejected" {
  command = plan

  variables {
    github_repository_ids = {
      sports-store-frontend        = 1349844546
      sports-store-auth-service    = 1349844338
      sports-store-catalog-service = 1349844250
      sports-store-cart-service    = 1349844165
      sports-store-order-service   = 1349844068
      sports-store-payment-service = 1349843991
      sports-store-gateway         = 1319569700
    }
  }

  expect_failures = [var.github_repository_ids]
}

run "duplicate_github_repository_id_is_rejected" {
  command = plan

  variables {
    github_repository_ids = {
      sports-store-frontend        = 1349844546
      sports-store-auth-service    = 1349844338
      sports-store-catalog-service = 1349844250
      sports-store-cart-service    = 1349844165
      sports-store-order-service   = 1349844068
      sports-store-payment-service = 1349844068
    }
  }

  expect_failures = [var.github_repository_ids]
}

run "zero_github_repository_id_is_rejected" {
  command = plan

  variables {
    github_repository_ids = {
      sports-store-frontend        = 1349844546
      sports-store-auth-service    = 0
      sports-store-catalog-service = 1349844250
      sports-store-cart-service    = 1349844165
      sports-store-order-service   = 1349844068
      sports-store-payment-service = 1349843991
    }
  }

  expect_failures = [var.github_repository_ids]
}

run "negative_github_repository_id_is_rejected" {
  command = plan

  variables {
    github_repository_ids = {
      sports-store-frontend        = 1349844546
      sports-store-auth-service    = -1349844338
      sports-store-catalog-service = 1349844250
      sports-store-cart-service    = 1349844165
      sports-store-order-service   = 1349844068
      sports-store-payment-service = 1349843991
    }
  }

  expect_failures = [var.github_repository_ids]
}

run "managed_node_group_configuration" {
  command = plan

  plan_options {
    target = [module.eks]
  }

  assert {
    condition = (
      length(local.managed_node_groups) == 1 &&
      toset(keys(local.managed_node_groups)) == toset(["default"]) &&
      local.managed_node_groups.default.instance_types == ["t3.medium"] &&
      local.managed_node_groups.default.capacity_type == "ON_DEMAND" &&
      local.managed_node_groups.default.min_size == 2 &&
      local.managed_node_groups.default.desired_size == 3 &&
      local.managed_node_groups.default.max_size == 4
    )
    error_message = "The single managed node group must use three desired On-Demand t3.medium nodes within the 2-4 boundaries."
  }

  assert {
    condition     = local.vpc_cni_configuration.env.ENABLE_PREFIX_DELEGATION == "false"
    error_message = "VPC CNI prefix delegation must remain disabled."
  }
}

run "deployment_principal_is_module_owned_only" {
  command = plan

  plan_options {
    target = [aws_eks_access_entry.approved_principals]
  }

  assert {
    condition     = length(aws_eks_access_entry.approved_principals) == 0
    error_message = "The standalone access-entry resource must not manage the deployment principal."
  }
}

run "additional_eks_principals_are_filtered_and_deduplicated" {
  command = plan

  variables {
    additional_eks_principal_arns = [
      "arn:aws:iam::123456789012:role/PlatformAdmin",
      "arn:aws:iam::123456789012:user/deploy-user",
      "arn:aws:iam::123456789012:role/PlatformAdmin",
    ]
  }

  plan_options {
    target = [
      aws_eks_access_entry.approved_principals,
      aws_eks_access_policy_association.approved_principals_admin,
    ]
  }

  assert {
    condition = toset(keys(aws_eks_access_entry.approved_principals)) == toset([
      "arn:aws:iam::123456789012:role/PlatformAdmin",
    ])
    error_message = "Additional principals must be deduplicated and the deployment principal must be filtered."
  }

  assert {
    condition = toset(keys(aws_eks_access_policy_association.approved_principals_admin)) == toset([
      "arn:aws:iam::123456789012:role/PlatformAdmin",
    ])
    error_message = "Each additional principal must retain the cluster-admin policy association."
  }
}

run "wrong_account_additional_eks_principal_is_rejected" {
  command = plan

  variables {
    additional_eks_principal_arns = [
      "arn:aws:iam::999999999999:role/WrongAccountAdmin",
    ]
  }

  plan_options {
    target = [aws_eks_access_entry.approved_principals]
  }

  expect_failures = [
    aws_eks_access_entry.approved_principals["arn:aws:iam::999999999999:role/WrongAccountAdmin"],
  ]
}

run "wrong_account_rejected" {
  command = plan

  plan_options {
    target = [terraform_data.expected_aws_account]
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "999999999999"
      arn        = "arn:aws:iam::999999999999:user/wrong-account"
      user_id    = "AIDAWRONGACCOUNT"
    }
  }

  expect_failures = [terraform_data.expected_aws_account]

}
