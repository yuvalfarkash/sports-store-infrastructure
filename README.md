# Sports Store AWS Infrastructure

Terraform in `terraform/` defines the Milestone 4 AWS foundation for Sports Store. It creates networking, an EKS control plane and managed node group, managed EKS add-ons, workload-specific IAM roles, and seven ECR repositories. It does not deploy application workloads.

## Architecture

- One VPC spanning two availability zones
- Two public subnets tagged for internet-facing load balancers
- Two private subnets tagged for internal load balancers
- One shared NAT Gateway for the course environment
- An EKS 1.34 cluster with a public API endpoint
- EKS `api`, `audit`, and `authenticator` control-plane logs retained in
  CloudWatch Logs for seven days
- One managed node group using `AL2023_x86_64_STANDARD` and `t3.large`
- EKS-managed CoreDNS, kube-proxy, VPC CNI, and EBS CSI add-ons
- Dedicated IRSA roles for EBS CSI and AWS Load Balancer Controller
- Seven immutable, scan-on-push ECR repositories
- A GitHub Actions OIDC role limited to ECR publishing from approved `main` branches

All Terraform-managed AWS resources receive the `Project=sports-store`, `Environment=dev`, and `ManagedBy=terraform` tags where AWS supports tagging.

CloudWatch is deliberately limited to EKS control-plane activity. Application
and NGINX stdout logs belong in the GitOps-managed Loki stack, so this
infrastructure does not install Container Insights, CloudWatch Agent, Fluent
Bit, or the `amazon-cloudwatch-observability` add-on. CloudWatch audit and API
records complement Loki workload logs; neither source replaces the other.

## Required tools

- Terraform 1.5.7 or newer
- An HCP Terraform account for the intended remote workflow
- AWS CLI and an AWS account with sufficient provisioning permissions
- Git and access to the `sports-store-infrastructure` repository

## HCP Terraform setup

The HCP Terraform organization and workspace must be created separately; their names are intentionally not hard-coded in this repository. This external setup cannot be validated from repository files alone.

Create a VCS-driven HCP Terraform workspace with:

- VCS repository: `sports-store-infrastructure`
- Terraform working directory: `terraform`
- VCS-driven speculative plans for changes
- Remote state stored and locked by HCP Terraform
- AWS authentication through HCP Terraform dynamic provider credentials/OIDC

Configure the required HCP Terraform project, workspace, variable set, AWS trust, and run permissions outside Git. Do not store long-lived AWS access keys in this repository or commit Terraform state.

## Initialize and validate

From the repository root:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform providers
```

For a local CLI review without configuring a backend:

```bash
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform plan
```

Do not use a local plan as a substitute for the reviewed VCS-driven HCP Terraform plan.

## Controlled apply

Review the HCP Terraform plan, expected resource counts, identity, region, and cost before approving an apply. Apply only through the authorized HCP Terraform workflow for this course environment. No application workload is deployed during Milestone 4.

Useful outputs after a successful apply include:

```bash
terraform -chdir=terraform output
terraform -chdir=terraform output -raw eks_cluster_name
terraform -chdir=terraform output -raw aws_load_balancer_controller_iam_role_arn
```

The outputs also expose the cluster endpoint, AWS region, VPC and subnet IDs, ECR URLs, GitHub ECR publishing role ARN, and EBS CSI role ARN.

## Destroy procedure

Remove application releases and externally managed load balancers before infrastructure teardown. Confirm persistent-data and backup requirements, then queue and approve a destroy plan through the authorized HCP Terraform workspace. Verify the plan carefully before applying the destroy operation.

## Cost warning

EKS, the NAT Gateway, EC2 managed-node instances, EBS volumes, load balancers, and data transfer can incur charges. A shared NAT Gateway reduces course-environment cost but is not highly available across availability zones. Monitor usage and destroy resources when they are no longer required.

At the configured desired capacity, expect one chargeable EKS control plane, one NAT Gateway, two `t3.large` EC2 nodes and their root EBS volumes, ECR image storage, and application EBS volumes such as the MongoDB PVC. Deploying the AWS Load Balancer Controller and application Ingress later can create one ALB plus related data-processing charges. Actual counts can change through autoscaling, upgrades, retained volumes, and workload configuration.
