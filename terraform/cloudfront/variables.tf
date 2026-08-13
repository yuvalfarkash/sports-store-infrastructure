variable "aws_region" {
  description = "AWS region containing the Sports Store ALB"
  type        = string
  default     = "eu-central-1"
}

variable "alb_origin_hostname" {
  description = "ALB DNS hostname discovered from the sports-store Ingress; an empty value disables CloudFront"
  type        = string
  default     = ""

  validation {
    condition = (
      var.alb_origin_hostname == "" ||
      (
        length(var.alb_origin_hostname) <= 253 &&
        can(regex("^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.)+elb\\.amazonaws\\.com$", var.alb_origin_hostname))
      )
    )
    error_message = "alb_origin_hostname must be empty or a valid AWS ELB hostname ending in .elb.amazonaws.com."
  }
}

variable "static_site_bucket_name" {
  description = "Name of the private S3 bucket created by the base Terraform root"
  type        = string
  default     = ""

  validation {
    condition     = var.static_site_bucket_name == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.static_site_bucket_name))
    error_message = "static_site_bucket_name must be empty or a valid DNS-compatible S3 bucket name."
  }
}

variable "static_site_bucket_arn" {
  description = "ARN of the private S3 bucket created by the base Terraform root"
  type        = string
  default     = ""

  validation {
    condition     = var.static_site_bucket_arn == "" || can(regex("^arn:aws:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.static_site_bucket_arn))
    error_message = "static_site_bucket_arn must be empty or an exact S3 bucket ARN in the aws partition."
  }
}

variable "static_site_bucket_regional_domain_name" {
  description = "Regional domain name of the private S3 bucket; never use a website endpoint"
  type        = string
  default     = ""

  validation {
    condition = (
      var.static_site_bucket_regional_domain_name == "" ||
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\\.s3[.-][a-z0-9-]+\\.amazonaws\\.com$", var.static_site_bucket_regional_domain_name))
    )
    error_message = "static_site_bucket_regional_domain_name must be empty or an AWS S3 regional REST endpoint."
  }
}
