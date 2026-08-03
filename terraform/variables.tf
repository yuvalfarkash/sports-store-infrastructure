variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "sports-store-cluster"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "github_organization" {
  description = "GitHub organization allowed to publish application images"
  type        = string
  default     = "sports-store-devops-team"
}

variable "github_repositories" {
  description = "GitHub repositories allowed to publish images from their main branches"
  type        = list(string)
  default = [
    "sports-store-frontend",
    "sports-store-gateway",
    "sports-store-auth-service",
    "sports-store-catalog-service",
    "sports-store-cart-service",
    "sports-store-order-service",
    "sports-store-payment-service",
  ]

  validation {
    condition = (
      length(var.github_repositories) == 7 &&
      length(distinct(var.github_repositories)) == 7 &&
      alltrue([
        for repository in var.github_repositories : contains([
          "sports-store-frontend",
          "sports-store-gateway",
          "sports-store-auth-service",
          "sports-store-catalog-service",
          "sports-store-cart-service",
          "sports-store-order-service",
          "sports-store-payment-service",
        ], repository)
      ])
    )
    error_message = "github_repositories must contain exactly the seven approved Sports Store application repositories."
  }
}
