locals {
  microservices = [
    "sports-store-frontend",
    "sports-store-gateway",
    "sports-store-auth-service",
    "sports-store-catalog-service",
    "sports-store-cart-service",
    "sports-store-order-service",
    "sports-store-payment-service"
  ]
}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.microservices)

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
