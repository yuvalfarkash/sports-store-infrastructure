resource "null_resource" "post_deploy" {
  # Ensure this runs after the EKS cluster is provisioned
  depends_on = [module.eks, helm_release.argocd]

  triggers = {
    cluster_name = var.cluster_name
    region       = var.aws_region
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      echo "Updating kubeconfig for cluster ${var.cluster_name} in region ${var.aws_region}..."
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}
    EOT
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      echo "Creating/Updating app-secrets in the cluster..."
      kubectl create secret generic app-secrets \
        --from-literal=mongodb-root-password=Gogoisgg \
        --from-literal=JWT_SECRET=my-super-secret-key-12345 \
        --dry-run=client -o yaml | kubectl apply -f -
    EOT
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      echo "Applying Argo CD Application manifest to trigger sync..."
      kubectl apply -f ../../sports-store-deployments/k8s/argocd-app.yaml
    EOT
  }
}
