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

  # A single controller replica is enough for this cluster and halves its
  # footprint on the t3.micro node group (chart default is 2, for HA).
  set {
    name  = "replicaCount"
    value = "1"
  }

  set {
    name  = "resources.requests.cpu"
    value = "20m"
  }

  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }

  set {
    name  = "resources.limits.memory"
    value = "128Mi"
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

  # This cluster has one static Application (see automation.tf) with no SSO,
  # so Dex and notifications are disabled - both unused pods that only eat
  # into the t3.micro node group's tight allocatable memory. The chart (7.4.4)
  # has no equivalent toggle for the ApplicationSet controller - its Deployment
  # template is unconditional - so that pod stays; it's small on its own.
  # Requests/limits below are sized for the t3.micro constraint.
  values = [
    yamlencode({
      dex           = { enabled = false }
      notifications = { enabled = false }
      controller = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { memory = "512Mi" }
        }
      }
      repoServer = {
        resources = {
          requests = { cpu = "30m", memory = "96Mi" }
          limits   = { memory = "384Mi" }
        }
      }
      server = {
        resources = {
          requests = { cpu = "30m", memory = "64Mi" }
          limits   = { memory = "128Mi" }
        }
      }
      redis = {
        resources = {
          requests = { cpu = "20m", memory = "32Mi" }
          limits   = { memory = "64Mi" }
        }
      }
    })
  ]

  # Ensure the helm release happens after EKS cluster is fully ready
  depends_on = [
    module.eks
  ]
}

resource "helm_release" "argocd_image_updater" {
  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  namespace  = "argocd"
  version    = "0.10.0"

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
    value = "https://${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  }

  set {
    name  = "config.registries[0].prefix"
    value = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  }

  set {
    name  = "config.registries[0].credentials"
    value = "ext:/scripts/ecr-login.sh"
  }

  set {
    name  = "config.registries[0].credsexpire"
    value = "10h"
  }

  values = [
    yamlencode({
      authScripts = {
        enabled = true
        scripts = {
          "ecr-login.sh" = "#!/bin/sh\nHOME=/tmp aws ecr get-login-password --region ${var.aws_region} | awk '{print \"AWS:\" $1}'\n"
        }
      }
      # The authScript spawns `aws` (python/botocore) as a subprocess on top
      # of the controller's own baseline - 64Mi was too tight and made that
      # subprocess slow enough to blow the script's fixed 10s timeout.
      resources = {
        requests = { cpu = "20m", memory = "64Mi" }
        limits   = { memory = "160Mi" }
      }
    })
  ]

  depends_on = [
    helm_release.argocd
  ]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.1"
  depends_on = [module.eks]
}
