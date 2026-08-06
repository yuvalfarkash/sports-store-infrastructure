resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.9.0"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.aws_load_balancer_controller_irsa.arn
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "region"
    value = "eu-central-1"
  }

  # Ensure the helm release happens after EKS cluster is fully ready
  depends_on = [
    module.eks
  ]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.4.4"

  # Ensure the helm release happens after EKS cluster is fully ready
  depends_on = [
    module.eks
  ]
}

resource "helm_release" "argocd_image_updater" {
  name             = "argocd-image-updater"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argocd-image-updater"
  namespace        = "argocd"
  version          = "0.10.0"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.argocd_image_updater_irsa.arn
  }
  
  set {
    name  = "config.registries[0].name"
    value = "ECR"
  }
  
  set {
    name  = "config.registries[0].api_url"
    value = "https://324621154117.dkr.ecr.eu-central-1.amazonaws.com"
  }
  
  set {
    name  = "config.registries[0].prefix"
    value = "324621154117.dkr.ecr.eu-central-1.amazonaws.com"
  }
  
  set {
    name  = "config.registries[0].credentials"
    value = "ext:/scripts/ecr-login.sh"
  }
  
  set {
    name  = "config.registries[0].credsexpire"
    value = "10h"
  }

  depends_on = [
    helm_release.argocd
  ]
}
