# Bootstraps the cluster with the shared app-secrets Secret and the root
# ArgoCD Application. Uses the kubernetes/kubectl providers (authenticated the
# same way as the helm provider above) instead of local-exec + kubectl/aws CLI,
# so this works the same way locally and under an HCP Terraform remote run —
# and, unlike a null_resource, updates correctly on repeated applies instead
# of only running once.

resource "kubernetes_secret" "app_secrets" {
  metadata {
    name      = "app-secrets"
    namespace = "default"
  }

  type = "Opaque"

  data = {
    "mongodb-root-password" = var.mongodb_root_password
    "JWT_SECRET"            = var.jwt_secret
  }

  depends_on = [module.eks]
}

locals {
  # name -> ECR repository, matching the Helm chart's per-service value paths.
  argocd_managed_images = {
    frontend = "sports-store-frontend"
    gateway  = "sports-store-gateway"
    auth     = "sports-store-auth-service"
    catalog  = "sports-store-catalog-service"
    cart     = "sports-store-cart-service"
    order    = "sports-store-order-service"
    payment  = "sports-store-payment-service"
  }

  argocd_image_list = join(",", [
    for name, repo in local.argocd_managed_images :
    "${name}=${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${repo}"
  ])

  argocd_app_annotations = merge(
    {
      "argocd-image-updater.argoproj.io/image-list"        = local.argocd_image_list
      "argocd-image-updater.argoproj.io/write-back-method" = "argocd"

      "argocd-image-updater.argoproj.io/frontend.helm.image-name" = "frontend.image.repository"
      "argocd-image-updater.argoproj.io/frontend.helm.image-tag"  = "frontend.image.tag"
      "argocd-image-updater.argoproj.io/gateway.helm.image-name"  = "gateway.image.repository"
      "argocd-image-updater.argoproj.io/gateway.helm.image-tag"   = "gateway.image.tag"
    },
    { for name in ["auth", "catalog", "cart", "order", "payment"] :
      "argocd-image-updater.argoproj.io/${name}.helm.image-name" => "services.${name}.image.repository"
    },
    { for name in ["auth", "catalog", "cart", "order", "payment"] :
      "argocd-image-updater.argoproj.io/${name}.helm.image-tag" => "services.${name}.image.tag"
    },
  )
}

# Root ArgoCD Application (app-of-apps bootstrap). This is the single source
# of truth for what gets deployed — sports-store-deployments/k8s no longer
# carries its own copy, so the two can't drift out of sync.
resource "kubectl_manifest" "argocd_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name        = "sports-store"
      namespace   = "argocd"
      annotations = local.argocd_app_annotations
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/${var.github_organization}/${var.deployments_repository}.git"
        path           = "helm/sports-store"
        targetRevision = "main"
        helm = {
          valueFiles = ["values.yaml", "values-aws.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "default"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  # The Application CRD only exists once ArgoCD itself is installed.
  depends_on = [helm_release.argocd]
}
