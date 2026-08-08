output "cloudfront_domain_name" {
  description = "Default CloudFront domain name, or null before an ALB origin is supplied"
  value       = local.cloudfront_enabled ? aws_cloudfront_distribution.sports_store[0].domain_name : null
}

output "cloudfront_https_url" {
  description = "Complete HTTPS URL for the Sports Store CloudFront distribution, or null when disabled"
  value       = local.cloudfront_enabled ? "https://${aws_cloudfront_distribution.sports_store[0].domain_name}" : null
}
