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

variable "deployments_repository" {
  description = "GitHub repository holding the Helm chart ArgoCD deploys"
  type        = string
  default     = "sports-store-deployments"
}

variable "teammate_iam_arns" {
  description = "IAM user/role ARNs granted direct kubectl access (via EKS access entries) alongside the Terraform apply identity"
  type        = list(string)
  default = [
    "arn:aws:iam::324621154117:user/the operator-sport",
    "arn:aws:iam::324621154117:user/Daniel-sport",
  ]
}

variable "mongodb_root_password" {
  description = "Root password for the Bitnami MongoDB chart's admin user. Supply through the HCP Terraform variable set (marked sensitive) or a gitignored *.auto.tfvars file — never commit a real value here."
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "Shared HS256 signing secret every backend service trusts to verify each other's JWTs. Supply through the HCP Terraform variable set (marked sensitive) or a gitignored *.auto.tfvars file — never commit a real value here."
  type        = string
  sensitive   = true
}
