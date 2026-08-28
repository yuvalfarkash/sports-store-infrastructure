mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/deploy-user"
      user_id    = "AIDATESTUSER"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "wrong_account_rejected" {
  command = plan

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

run "disabled_without_an_origin" {
  command = plan

  assert {
    condition     = length(aws_cloudfront_distribution.sports_store) == 0
    error_message = "CloudFront must not be created before an ALB hostname is supplied."
  }

  assert {
    condition     = output.cloudfront_domain_name == null && output.cloudfront_https_url == null
    error_message = "CloudFront outputs must remain null while the distribution is disabled."
  }
}

run "enabled_with_a_valid_alb_origin" {
  command = plan

  variables {
    alb_origin_hostname                     = "k8s-sportsstore-1234567890.eu-central-1.elb.amazonaws.com"
    static_site_bucket_name                 = "sports-store-static-123456789012-eu-central-1"
    static_site_bucket_arn                  = "arn:aws:s3:::sports-store-static-123456789012-eu-central-1"
    static_site_bucket_regional_domain_name = "sports-store-static-123456789012-eu-central-1.s3.eu-central-1.amazonaws.com"
  }

  assert {
    condition     = length(aws_cloudfront_distribution.sports_store) == 1
    error_message = "Exactly one distribution must be planned for a valid ALB hostname."
  }

  assert {
    condition = (
      aws_cloudfront_distribution.sports_store[0].enabled &&
      aws_cloudfront_distribution.sports_store[0].price_class == "PriceClass_100" &&
      aws_cloudfront_distribution.sports_store[0].viewer_certificate[0].cloudfront_default_certificate
    )
    error_message = "The distribution must use the low-cost price class and default CloudFront certificate."
  }

  assert {
    condition = (
      one([for origin in aws_cloudfront_distribution.sports_store[0].origin : origin if origin.origin_id == local.alb_origin_id]).domain_name == var.alb_origin_hostname &&
      one(one([for origin in aws_cloudfront_distribution.sports_store[0].origin : origin if origin.origin_id == local.alb_origin_id]).custom_origin_config).origin_protocol_policy == "http-only"
    )
    error_message = "CloudFront must use the discovered ALB hostname over HTTP."
  }

  assert {
    condition = (
      aws_cloudfront_distribution.sports_store[0].ordered_cache_behavior[0].path_pattern == "/api/*" &&
      aws_cloudfront_distribution.sports_store[0].ordered_cache_behavior[0].target_origin_id == local.alb_origin_id &&
      aws_cloudfront_distribution.sports_store[0].ordered_cache_behavior[0].cache_policy_id == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" &&
      aws_cloudfront_distribution.sports_store[0].ordered_cache_behavior[0].origin_request_policy_id == "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    )
    error_message = "The safe dynamic cache and request-forwarding policies must remain selected."
  }

  assert {
    condition = (
      toset(aws_cloudfront_distribution.sports_store[0].ordered_cache_behavior[0].allowed_methods) ==
      toset(["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]) &&
      toset(aws_cloudfront_distribution.sports_store[0].ordered_cache_behavior[0].cached_methods) ==
      toset(["GET", "HEAD"])
    )
    error_message = "All application/API methods must be allowed while CloudFront's schema caches only GET and HEAD."
  }


  assert {
    condition = (
      aws_cloudfront_distribution.sports_store[0].default_root_object == "index.html" &&
      aws_cloudfront_distribution.sports_store[0].default_cache_behavior[0].target_origin_id == local.s3_origin_id &&
      aws_cloudfront_distribution.sports_store[0].default_cache_behavior[0].cache_policy_id == local.caching_disabled_policy_id &&
      toset(aws_cloudfront_distribution.sports_store[0].default_cache_behavior[0].allowed_methods) == toset(["GET", "HEAD"]) &&
      aws_cloudfront_distribution.sports_store[0].ordered_cache_behavior[1].path_pattern == "/assets/*" &&
      aws_cloudfront_distribution.sports_store[0].ordered_cache_behavior[1].target_origin_id == local.s3_origin_id &&
      toset(aws_cloudfront_distribution.sports_store[0].ordered_cache_behavior[1].allowed_methods) == toset(["GET", "HEAD"])
    )
    error_message = "S3 must serve the default and cached assets behaviors while API stays first."
  }

  assert {
    condition = (
      aws_cloudfront_origin_access_control.static_site[0].signing_behavior == "always" &&
      aws_cloudfront_origin_access_control.static_site[0].signing_protocol == "sigv4" &&
      one(aws_cloudfront_distribution.sports_store[0].default_cache_behavior[0].function_association).event_type == "viewer-request"
    )
    error_message = "The private S3 origin must use signed OAC requests and the default behavior must use the SPA rewrite function."
  }


  assert {
    condition = (
      aws_s3_bucket_policy.cloudfront_static_site[0].bucket == var.static_site_bucket_name &&
      data.aws_iam_policy_document.cloudfront_static_site[0].statement[0].actions == toset(["s3:GetObject"]) &&
      data.aws_iam_policy_document.cloudfront_static_site[0].statement[0].resources == toset(["${var.static_site_bucket_arn}/*"]) &&
      one(data.aws_iam_policy_document.cloudfront_static_site[0].statement[0].principals).identifiers == toset(["cloudfront.amazonaws.com"]) &&
      one(data.aws_iam_policy_document.cloudfront_static_site[0].statement[0].condition).test == "StringEquals" &&
      one(data.aws_iam_policy_document.cloudfront_static_site[0].statement[0].condition).variable == "AWS:SourceArn"
    )
    error_message = "The bucket policy must grant only GetObject to CloudFront for the exact distribution ARN."
  }
}

run "rejects_a_non_alb_origin" {
  command = plan

  variables {
    alb_origin_hostname = "https://example.com/not-an-alb"
  }

  expect_failures = [var.alb_origin_hostname]
}

run "rejects_mismatched_s3_origin_inputs" {
  command = plan

  variables {
    alb_origin_hostname                     = "k8s-sportsstore-1234567890.eu-central-1.elb.amazonaws.com"
    static_site_bucket_name                 = "sports-store-static-123456789012-eu-central-1"
    static_site_bucket_arn                  = "arn:aws:s3:::different-static-bucket"
    static_site_bucket_regional_domain_name = "sports-store-static-123456789012-eu-central-1.s3.eu-central-1.amazonaws.com"
  }

  expect_failures = [terraform_data.complete_origin_inputs]
}
