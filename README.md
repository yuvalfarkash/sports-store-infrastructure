# Sports Store AWS Infrastructure

Terraform in `terraform/` defines the Milestone 4 AWS foundation for Sports Store. It creates networking, an EKS control plane and managed node group, managed EKS add-ons, workload-specific IAM roles, seven ECR repositories, the application secret container, and External Secrets Operator. Application workloads remain GitOps-managed rather than being declared directly in Terraform.

## Architecture

- One VPC spanning two availability zones
- Two public subnets tagged for internet-facing load balancers
- Two private subnets tagged for internal load balancers
- One shared NAT Gateway for the course environment
- An EKS 1.34 cluster with a public API endpoint
- EKS `api`, `audit`, and `authenticator` control-plane logs retained in
  CloudWatch Logs for seven days
- One managed node group using `AL2023_x86_64_STANDARD` and `t3.micro`, sized
  for the course budget rather than headroom
- Argo CD, External Secrets Operator chart `2.8.0`, the AWS Load Balancer Controller, and Argo CD Image Updater are
  configured with reduced resource usage in `helm.tf`
- EKS-managed CoreDNS, kube-proxy, VPC CNI, and EBS CSI add-ons
- Dedicated IRSA roles for EBS CSI, AWS Load Balancer Controller, and External Secrets Operator
- An AWS Secrets Manager container named `sports-store/production/app`; Terraform creates no secret version
- Seven immutable, scan-on-push ECR repositories
- A GitHub Actions OIDC role limited to ECR publishing from approved `main` branches

All Terraform-managed AWS resources receive the `Project=sports-store`, `Environment=dev`, and `ManagedBy=terraform` tags where AWS supports tagging.

CloudWatch currently collects EKS control-plane logs only. Application and
NGINX workload log collection is intentionally deferred because Loki and Alloy
were removed to fit the current cluster resource limits.

## Required tools

- Terraform 1.5.7 or newer
- An HCP Terraform account for the intended remote workflow
- AWS CLI and an AWS account with sufficient provisioning permissions
- Git and access to the `sports-store-infrastructure` repository
- Bash, OpenSSL, and AWS CLI for the one-time application-secret bootstrap

## HCP Terraform setup

The HCP Terraform organization and workspace must be created separately; their names are intentionally not hard-coded in this repository. This external setup cannot be validated from repository files alone.

Create a VCS-driven HCP Terraform workspace with:

- VCS repository: `sports-store-infrastructure`
- Terraform working directory: `terraform`
- VCS-driven speculative plans for changes
- Remote state stored and locked by HCP Terraform
- AWS authentication through HCP Terraform dynamic provider credentials/OIDC

Configure the required HCP Terraform project, workspace, variable set, AWS trust, and run permissions outside Git. Remove any legacy `mongodb_root_password` and `jwt_secret` workspace variables: this configuration no longer accepts them. Do not store long-lived AWS access keys in this repository or commit Terraform state.

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

Review the HCP Terraform plan, expected resource counts, identity, region, and cost before approving an apply. Apply only through the authorized HCP Terraform workflow for this course environment. Terraform installs platform operators and the Argo CD bootstrap Application, but it does not declare the Sports Store Deployments, Services, or MongoDB workload.

Useful outputs after a successful apply include:

```bash
terraform -chdir=terraform output
terraform -chdir=terraform output -raw eks_cluster_name
terraform -chdir=terraform output -raw aws_load_balancer_controller_iam_role_arn
terraform -chdir=terraform output -raw application_secret_name
terraform -chdir=terraform output -raw application_secret_arn
terraform -chdir=terraform output -raw external_secrets_iam_role_arn
```

The outputs also expose the cluster endpoint, AWS region, VPC and subnet IDs, ECR URLs, GitHub ECR publishing role ARN, and EBS CSI role ARN. All outputs are metadata and contain no secret value.

## Application secret workflow

AWS Secrets Manager is the source of truth. Terraform creates only the deterministic `sports-store/production/app` container and metadata; it deliberately has no `aws_secretsmanager_secret_version` resource. External Secrets Operator runs in the dedicated `external-secrets` namespace. Its Helm-created `external-secrets` ServiceAccount is annotated with a least-privilege IRSA role whose trust is restricted to that exact namespace and ServiceAccount and whose policy can only describe/read this secret ARN.

After the first successful Terraform apply, Yuval must populate the first version manually from a machine authenticated to the intended AWS account:

```bash
bash scripts/bootstrap-application-secrets.sh --check
bash scripts/bootstrap-application-secrets.sh
```

The script reads `aws_region` and `application_secret_name` from Terraform outputs. Set `AWS_REGION` (or `AWS_DEFAULT_REGION`) and `SPORTS_STORE_SECRET_ID` to use explicit values instead. It displays only account ID, caller ARN, region, secret name, and version presence; generated values and JSON are never printed. The first write requires typing `yes`. A normal run refuses to overwrite `AWSCURRENT`; `--rotate` is an explicit break-glass operation, not part of deployment.

The required order is:

```text
Terraform apply
-> bootstrap AWS secret values
-> wait for ExternalSecret synchronization
-> verify app-secrets exists
-> verify MongoDB and application workloads
```

Verify synchronization without reading values:

```bash
kubectl get secretstore,externalsecret -n sports-store
kubectl describe secretstore sports-store-aws-secrets -n sports-store
kubectl describe externalsecret app-secrets -n sports-store
kubectl wait --for=condition=Ready externalsecret/app-secrets -n sports-store --timeout=120s
kubectl get secret app-secrets -n sports-store -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}'
kubectl get pods -n sports-store
```

The final command lists keys only. The expected keys are `mongodb-root-password`, `JWT_SECRET`, and the five `*_MONGO_URI` keys. Never use a command that prints `.data`, decoded values, or the AWS `SecretString` during routine verification.

No secret value belongs in Git, Terraform variables, Terraform state, Helm values, command history, CI logs, or ordinary terminal output. Existing historical state created by the removed Kubernetes Secret resource must remain access-controlled under the existing state-retention policy; the new configuration supplies no secret inputs and stores no application secret values in future state snapshots.

External Secrets refreshes the Kubernetes Secret on its configured interval. Pods that consume keys as environment variables must be restarted to observe a changed JWT, and old JWTs become invalid after all services use the new signing key. Do not use the bootstrap script's `--rotate` option for a JWT-only change: it regenerates both properties. The MongoDB root password is persisted inside the database, so changing only AWS/Kubernetes data does not update MongoDB and will break authentication. MongoDB rotation requires a separate coordinated procedure covering the database credential, AWS secret update, ExternalSecret sync, and controlled workload restarts.

An expected first plan creates the Secrets Manager metadata container, the scoped IAM role and inline read policy, the `external-secrets` namespace, the pinned operator Helm release, and updates the Argo CD Application dependency/revision. It destroys the old Terraform-managed `kubernetes_secret.app_secrets`. Review that removal carefully; do not run a normal deployment until the AWS secret is bootstrapped and the GitOps chart change is available on `dev-branch`.

## Destroy procedure

Remove application releases and externally managed load balancers before infrastructure teardown. Confirm persistent-data and backup requirements, then queue and approve a destroy plan through the authorized HCP Terraform workspace. Verify the plan carefully before applying the destroy operation.

The application secret sets `recovery_window_in_days = 0`. Terraform destroy therefore permanently deletes its container and versions instead of leaving the deterministic name scheduled for deletion, allowing a later course-environment apply to recreate the same name. This is intentionally irreversible: preserve any values needed for recovery through an approved secret backup/rotation procedure before destroy. AWS deletion is asynchronous, so an immediate recreate can still require a short retry with backoff.

## Cost warning

EKS, the NAT Gateway, EC2 managed-node instances, EBS volumes, load balancers, and data transfer can incur charges. A shared NAT Gateway reduces course-environment cost but is not highly available across availability zones. Monitor usage and destroy resources when they are no longer required.

At the configured desired capacity, expect one chargeable EKS control plane, one NAT Gateway, up to six `t3.micro` EC2 nodes and their root EBS volumes, ECR image storage, and application EBS volumes such as the MongoDB PVC. Deploying the AWS Load Balancer Controller and application Ingress later can create one ALB plus related data-processing charges. Actual counts can change through autoscaling, upgrades, retained volumes, and workload configuration.
