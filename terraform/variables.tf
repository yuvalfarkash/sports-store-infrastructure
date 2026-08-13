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
    "sports-store-auth-service",
    "sports-store-catalog-service",
    "sports-store-cart-service",
    "sports-store-order-service",
    "sports-store-payment-service",
  ]

  validation {
    condition = (
      length(var.github_repositories) == 5 &&
      length(distinct(var.github_repositories)) == 5 &&
      alltrue([
        for repository in var.github_repositories : contains([
          "sports-store-auth-service",
          "sports-store-catalog-service",
          "sports-store-cart-service",
          "sports-store-order-service",
          "sports-store-payment-service",
        ], repository)
      ])
    )
    error_message = "github_repositories must contain exactly the five approved Sports Store backend image repositories."
  }
}

variable "deployments_repository" {
  description = "GitHub repository holding the Helm chart ArgoCD deploys"
  type        = string
  default     = "sports-store-deployments"
}

variable "additional_eks_principal_arns" {
  description = "Additional explicit same-account IAM user/role ARNs granted EKS cluster-admin access"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.additional_eks_principal_arns :
      can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/[A-Za-z0-9+=,.@_/-]+$", arn))
    ])
    error_message = "Every additional EKS principal must be an explicit IAM user or role ARN; root and wildcard principals are forbidden."
  }
}
