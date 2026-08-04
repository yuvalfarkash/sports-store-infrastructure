output "eks_cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "The endpoint for your EKS Kubernetes API"
  value       = module.eks.cluster_endpoint
}

output "aws_region" {
  description = "AWS region containing the infrastructure"
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the Sports Store VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "ecr_repository_urls" {
  description = "URLs of the created ECR repositories"
  value       = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "github_actions_ecr_publishing_role_arn" {
  description = "IAM role ARN used by approved GitHub Actions main-branch workflows to publish ECR images"
  value       = aws_iam_role.github_ecr_publisher.arn
}

output "ebs_csi_iam_role_arn" {
  description = "IRSA IAM role ARN for the EBS CSI controller"
  value       = module.ebs_csi_irsa.arn
}

output "aws_load_balancer_controller_iam_role_arn" {
  description = "IRSA IAM role ARN for AWS Load Balancer Controller"
  value       = module.aws_load_balancer_controller_irsa.arn
}
