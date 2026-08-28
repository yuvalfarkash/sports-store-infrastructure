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
  description = "GitHub organization login allowed to publish application artifacts"
  type        = string
  default     = "yuvalfarkash"

  validation {
    condition     = var.github_organization == "yuvalfarkash"
    error_message = "github_organization must be exactly yuvalfarkash."
  }
}

variable "github_organization_id" {
  description = "Immutable GitHub organization ID allowed to publish application artifacts"
  type        = number
  default     = 78908574

  validation {
    condition     = var.github_organization_id == 78908574
    error_message = "github_organization_id must be exactly 78908574."
  }
}

variable "github_repository_ids" {
  description = "Exact approved GitHub repository names mapped to their immutable repository IDs"
  type        = map(number)
  default = {
    sports-store-frontend        = 1349844546
    sports-store-auth-service    = 1349844338
    sports-store-catalog-service = 1349844250
    sports-store-cart-service    = 1349844165
    sports-store-order-service   = 1349844068
    sports-store-payment-service = 1349843991
  }

  validation {
    condition = toset(keys(var.github_repository_ids)) == toset([
      "sports-store-frontend",
      "sports-store-auth-service",
      "sports-store-catalog-service",
      "sports-store-cart-service",
      "sports-store-order-service",
      "sports-store-payment-service",
    ])
    error_message = "github_repository_ids must contain exactly the six approved Sports Store repositories."
  }

  validation {
    condition     = alltrue([for id in values(var.github_repository_ids) : id > 0 && floor(id) == id])
    error_message = "Every GitHub repository ID must be a positive integer."
  }

  validation {
    condition     = length(distinct(values(var.github_repository_ids))) == length(var.github_repository_ids)
    error_message = "Every approved GitHub repository must have a unique repository ID."
  }

  validation {
    condition = var.github_repository_ids == tomap({
      sports-store-frontend        = 1349844546
      sports-store-auth-service    = 1349844338
      sports-store-catalog-service = 1349844250
      sports-store-cart-service    = 1349844165
      sports-store-order-service   = 1349844068
      sports-store-payment-service = 1349843991
    })
    error_message = "github_repository_ids must exactly match the reviewed GitHub API identity audit."
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
