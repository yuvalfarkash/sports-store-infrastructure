mock_provider "aws" {}

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
    alb_origin_hostname = "k8s-sportsstore-1234567890.eu-central-1.elb.amazonaws.com"
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
      one(aws_cloudfront_distribution.sports_store[0].origin).domain_name == var.alb_origin_hostname &&
      one(one(aws_cloudfront_distribution.sports_store[0].origin).custom_origin_config).origin_protocol_policy == "http-only"
    )
    error_message = "CloudFront must use the discovered ALB hostname over HTTP."
  }

  assert {
    condition = (
      aws_cloudfront_distribution.sports_store[0].default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https" &&
      aws_cloudfront_distribution.sports_store[0].default_cache_behavior[0].cache_policy_id == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" &&
      aws_cloudfront_distribution.sports_store[0].default_cache_behavior[0].origin_request_policy_id == "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    )
    error_message = "The safe dynamic cache and request-forwarding policies must remain selected."
  }

  assert {
    condition = (
      toset(aws_cloudfront_distribution.sports_store[0].default_cache_behavior[0].allowed_methods) ==
      toset(["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]) &&
      toset(aws_cloudfront_distribution.sports_store[0].default_cache_behavior[0].cached_methods) ==
      toset(["GET", "HEAD"])
    )
    error_message = "All application/API methods must be allowed while CloudFront's schema caches only GET and HEAD."
  }
}

run "rejects_a_non_alb_origin" {
  command = plan

  variables {
    alb_origin_hostname = "https://example.com/not-an-alb"
  }

  expect_failures = [var.alb_origin_hostname]
}
