#!/usr/bin/env bash
set -euo pipefail

# Root of the infrastructure repo
INFRA_ROOT="$(git rev-parse --show-toplevel)"
cd "$INFRA_ROOT/terraform"

echo "=== Running Terraform apply ==="
terraform apply -auto-approve

printf '%s\n' \
  '=== Application secret bootstrap is manual ===' \
  'Terraform created the AWS Secrets Manager container but did not create a secret version.' \
  'From the repository root, verify identity and status, then populate the first version:' \
  '  bash scripts/bootstrap-application-secrets.sh --check' \
  '  bash scripts/bootstrap-application-secrets.sh' \
  'Do not use --rotate during a normal deployment.'

# List of microservice repositories (same as var.github_repositories)
REPOS=(
  "sports-store-frontend"
  "sports-store-gateway"
  "sports-store-auth-service"
  "sports-store-catalog-service"
  "sports-store-cart-service"
  "sports-store-order-service"
  "sports-store-payment-service"
)

# GitHub organization
ORG="sports-store-devops-team"

echo "=== Triggering CI workflows for all microservices ==="
for REPO in "${REPOS[@]}"; do
  echo "Triggering CI for $REPO"
  # Each repo has exactly one workflow file: .github/workflows/ci.yaml
  gh workflow run ci.yaml -R "$ORG/$REPO" --ref main || echo "Failed to trigger CI for $REPO"
done

echo "All triggers dispatched."
