locals {
  origin_inputs = [
    var.alb_origin_hostname,
    var.static_site_bucket_name,
    var.static_site_bucket_arn,
    var.static_site_bucket_regional_domain_name,
  ]
  cloudfront_enabled = alltrue([for value in local.origin_inputs : value != ""])
  alb_origin_id      = "sports-store-alb"
  s3_origin_id       = "sports-store-private-s3"
  origin_inputs_match = !local.cloudfront_enabled || (
    var.static_site_bucket_name == "sports-store-static-${data.aws_caller_identity.current.account_id}-${var.aws_region}" &&
    var.static_site_bucket_arn == "arn:aws:s3:::${var.static_site_bucket_name}" &&
    var.static_site_bucket_regional_domain_name == "${var.static_site_bucket_name}.s3.${var.aws_region}.amazonaws.com"
  )

  # Stable AWS-managed policies. The API behavior forwards cookies, query
  # strings, Authorization, CORS headers, and all viewer headers except Host.
  caching_disabled_policy_id              = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  all_viewer_except_host_origin_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
}

resource "terraform_data" "complete_origin_inputs" {
  input = local.origin_inputs

  lifecycle {
    precondition {
      condition     = alltrue([for value in local.origin_inputs : value == ""]) || local.cloudfront_enabled
      error_message = "CloudFront origin inputs must either all be empty or all be supplied."
    }

    precondition {
      condition     = local.origin_inputs_match
      error_message = "The static bucket name, ARN, regional domain name, and AWS region must identify the same bucket."
    }
  }
}

resource "aws_cloudfront_origin_access_control" "static_site" {
  count = local.cloudfront_enabled ? 1 : 0

  name                              = "sports-store-private-s3"
  description                       = "Signed CloudFront access to the private Sports Store frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "spa_rewrite" {
  count = local.cloudfront_enabled ? 1 : 0

  name    = "sports-store-spa-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite extensionless frontend routes to index.html"
  publish = true
  code    = file("${path.module}/spa-rewrite.js")
}

resource "aws_cloudfront_cache_policy" "hashed_assets" {
  count = local.cloudfront_enabled ? 1 : 0

  name        = "sports-store-hashed-assets"
  comment     = "Long-lived caching for Vite content-hashed assets"
  default_ttl = 31536000
  max_ttl     = 31536000
  min_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

resource "aws_cloudfront_distribution" "sports_store" {
  count = local.cloudfront_enabled ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Sports Store course environment"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  wait_for_deployment = true

  origin {
    domain_name = var.static_site_bucket_regional_domain_name
    origin_id   = local.s3_origin_id

    origin_access_control_id = aws_cloudfront_origin_access_control.static_site[0].id

    s3_origin_config {
      origin_access_identity = ""
    }
  }

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

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = local.alb_origin_id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = local.caching_disabled_policy_id
    origin_request_policy_id = local.all_viewer_except_host_origin_policy_id
  }

  ordered_cache_behavior {
    path_pattern           = "/assets/*"
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]
    cache_policy_id = aws_cloudfront_cache_policy.hashed_assets[0].id
  }

  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]
    cache_policy_id = local.caching_disabled_policy_id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_rewrite[0].arn
    }
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

  depends_on = [terraform_data.complete_origin_inputs]
}

data "aws_iam_policy_document" "cloudfront_static_site" {
  count = local.cloudfront_enabled ? 1 : 0

  statement {
    sid       = "AllowCloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${var.static_site_bucket_arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.sports_store[0].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudfront_static_site" {
  count = local.cloudfront_enabled ? 1 : 0

  bucket = var.static_site_bucket_name
  policy = data.aws_iam_policy_document.cloudfront_static_site[0].json
}
