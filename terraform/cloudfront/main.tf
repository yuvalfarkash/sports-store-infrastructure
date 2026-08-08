locals {
  cloudfront_enabled = var.alb_origin_hostname != ""
  alb_origin_id      = "sports-store-alb"

  # AWS-managed policies are global and have stable IDs. CachingDisabled keeps
  # every application response dynamic. AllViewerExceptHostHeader forwards
  # cookies, query strings, Authorization, CORS preflight headers, and all other
  # viewer headers while allowing CloudFront to generate the ALB Host header.
  caching_disabled_policy_id              = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  all_viewer_except_host_origin_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
}

resource "aws_cloudfront_distribution" "sports_store" {
  count = local.cloudfront_enabled ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Sports Store course environment"
  price_class         = "PriceClass_100"
  wait_for_deployment = true

  origin {
    domain_name = var.alb_origin_hostname
    origin_id   = local.alb_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = local.alb_origin_id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    allowed_methods = [
      "DELETE",
      "GET",
      "HEAD",
      "OPTIONS",
      "PATCH",
      "POST",
      "PUT",
    ]
    cached_methods = ["GET", "HEAD"]

    cache_policy_id          = local.caching_disabled_policy_id
    origin_request_policy_id = local.all_viewer_except_host_origin_policy_id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = local.common_tags
}
