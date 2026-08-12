module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                  = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.common_tags
}

module "aws_load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                                   = "${var.cluster_name}-aws-load-balancer-controller"
  use_name_prefix                        = false
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.common_tags
}

module "argocd_image_updater_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.cluster_name}-argocd-image-updater"
  use_name_prefix = false

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["argocd:argocd-image-updater"]
    }
  }

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "argocd_image_updater_ecr_read" {
  role       = "${var.cluster_name}-argocd-image-updater"
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  depends_on = [module.argocd_image_updater_irsa]
}

# Grants explicitly approved same-account principals direct kubectl access.
locals {
  approved_eks_principal_arns = concat(
    [local.deployment_principal],
    var.additional_eks_principal_arns,
  )
}

resource "aws_eks_access_entry" "approved_principals" {
  for_each = toset(local.approved_eks_principal_arns)

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value

  lifecycle {
    precondition {
      condition     = split(":", each.value)[4] == local.expected_account_id
      error_message = "EKS principal ${each.value} is outside expected AWS account ${local.expected_account_id}."
    }
  }
}

resource "aws_eks_access_policy_association" "approved_principals_admin" {
  for_each = aws_eks_access_entry.approved_principals

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
