resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.9.0"
  wait       = true
  timeout    = 600

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
    value = var.aws_region
  }

  # A single controller replica is enough for this course cluster and halves
  # the chart default footprint. This controller is not highly available.
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

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = kubernetes_namespace_v1.external_secrets.metadata[0].name
  version    = "2.8.0"
  wait       = true
  timeout    = 600

  values = [
    yamlencode({
      installCRDs = true
      serviceAccount = {
        create = true
        name   = local.external_secrets_service_account
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_secrets.arn
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.external_secrets,
    aws_iam_role_policy.external_secrets,
    helm_release.aws_load_balancer_controller,
  ]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.4.4"
  wait             = true
  timeout          = 600

  # This cluster has one static Application (see automation.tf) with no SSO,
  # so Dex and notifications are disabled - both would be unused pods. The chart (7.4.4)
  # has no equivalent toggle for the ApplicationSet controller - its Deployment
  # template is unconditional - so that pod stays; it's small on its own.
  # Requests/limits below are included in the t3.medium capacity audit.
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

  # The controller's ready webhook Service must exist before charts that
  # create Services can begin installation.
  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

resource "helm_release" "argocd_image_updater" {
  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  namespace  = "argocd"
  version    = "0.10.0"
  wait       = true
  timeout    = 600

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
  wait       = true
  timeout    = 600
  depends_on = [helm_release.aws_load_balancer_controller]
}
