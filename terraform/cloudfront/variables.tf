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
