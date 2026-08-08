# Sports Store AWS Infrastructure

Terraform in `terraform/` defines the Milestone 4 AWS foundation for Sports Store. It creates networking, an EKS control plane and managed node group, managed EKS add-ons, workload-specific IAM roles, seven ECR repositories, the application secret container, and External Secrets Operator. The isolated `terraform/cloudfront/` root manages the public CloudFront distribution after Kubernetes has produced an ALB hostname. Application workloads remain GitOps-managed rather than being declared directly in Terraform.

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
- A low-cost `PriceClass_100` CloudFront distribution using its default domain and certificate

All Terraform-managed AWS resources receive the `Project=sports-store`, `Environment=dev`, and `ManagedBy=terraform` tags where AWS supports tagging.

The external request path is:

```text
User -> CloudFront -> ALB -> Ingress -> Gateway -> application services
```

Viewers are redirected from HTTP to HTTPS at CloudFront. CloudFront currently connects to the internet-facing ALB over HTTP. The ALB remains directly accessible by design for troubleshooting; there is no secret origin header, CloudFront-only security-group rule, custom domain, Route 53 record, or ACM certificate.

CloudWatch currently collects EKS control-plane logs only. Application and
NGINX workload log collection is intentionally deferred because Loki and Alloy
were removed to fit the current cluster resource limits.

## Required tools

- Terraform 1.5.7 or newer
- An HCP Terraform account for the intended remote workflow
- AWS CLI and an AWS account with sufficient provisioning permissions
- Git and access to the `sports-store-infrastructure` repository
- Bash, OpenSSL, and AWS CLI for the one-time application-secret bootstrap
- `kubectl` and GitHub CLI (`gh`) for the deployment workflow

## HCP Terraform setup

The HCP Terraform organization and workspace must be created separately; their names are intentionally not hard-coded in this repository. This external setup cannot be validated from repository files alone.

Create a VCS-driven HCP Terraform workspace for the base root with:

- VCS repository: `sports-store-infrastructure`
- Terraform working directory: `terraform`
- VCS-driven speculative plans for changes
- Remote state stored and locked by HCP Terraform
- AWS authentication through HCP Terraform dynamic provider credentials/OIDC

Configure the required HCP Terraform project, workspace, variable set, AWS trust, and run permissions outside Git. Remove any legacy `mongodb_root_password` and `jwt_secret` workspace variables: this configuration no longer accepts them. Do not store long-lived AWS access keys in this repository or commit Terraform state.

The CloudFront root has independent lifecycle and state so a repeated stage-1 apply cannot plan deletion of an existing distribution merely because an ALB hostname is not yet available as an input. Configure a second state/backend for working directory `terraform/cloudfront`; do not point both roots at the same state. Preserve and lock both states. The deployment and destroy scripts expect each root's backend to have been initialized on Yuval's workstation.

## Initialize and validate

From the repository root:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform providers
terraform -chdir=terraform/cloudfront init
terraform -chdir=terraform/cloudfront fmt -check -recursive
terraform -chdir=terraform/cloudfront validate
terraform -chdir=terraform/cloudfront test
```

For a local CLI review without configuring a backend:

```bash
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform plan
```

Do not use a local plan as a substitute for the reviewed VCS-driven HCP Terraform plan.

## Two-stage deployment

The ALB is created asynchronously by AWS Load Balancer Controller only after Argo CD creates the Helm Ingress. Terraform therefore cannot know the ALB hostname during the initial base plan. The two independent roots avoid a circular dependency and require no provisioner, generated variable file, direct AWS CLI CloudFront mutation, or Terraform state manipulation.

On an AWS-authenticated workstation with both Terraform backends initialized, Yuval reviews the expected plans and runs from the repository root:

```bash
bash deploy.sh
```

The script performs this sequence:

1. Applies the base `terraform/` root and waits for Terraform to finish.
2. Triggers each application workflow from `main` and configures `kubectl` from the `eks_cluster_name` and `aws_region` Terraform outputs.
3. Waits up to five minutes for the `sports-store` Argo CD Application, then up to 20 minutes for `sports-store/sports-store` Ingress to receive a hostname. It polls every 10 seconds, validates the value as an AWS ELB hostname, and fails without invoking stage 2 on timeout or invalid data. The three waits are configurable with positive-integer `ARGO_APPLICATION_TIMEOUT_SECONDS`, `ALB_HOSTNAME_TIMEOUT_SECONDS`, and `KUBERNETES_POLL_SECONDS` environment variables.
4. Applies `terraform/cloudfront/` with the validated hostname and region, waits for CloudFront deployment, then prints the CloudFront HTTPS URL and direct ALB HTTP URL.

On a clean deployment the CloudFront root contains no distribution until stage 2 receives a valid hostname. On a repeated deployment, the base root cannot alter the distribution because it has separate state; stage 2 idempotently reconciles the existing distribution with the current Ingress hostname. This also accommodates an ALB replacement.

Terraform installs platform operators and the Argo CD bootstrap Application, but it does not declare the Sports Store Deployments, Services, or MongoDB workload. The first deployment still requires the manual application-secret bootstrap described below; the deployment script never reads or prints secret values.

Useful outputs after a successful apply include:

```bash
terraform -chdir=terraform output
terraform -chdir=terraform output -raw eks_cluster_name
terraform -chdir=terraform output -raw aws_load_balancer_controller_iam_role_arn
terraform -chdir=terraform output -raw application_secret_name
terraform -chdir=terraform output -raw application_secret_arn
terraform -chdir=terraform output -raw external_secrets_iam_role_arn
terraform -chdir=terraform/cloudfront output -raw cloudfront_domain_name
terraform -chdir=terraform/cloudfront output -raw cloudfront_https_url
```

The outputs also expose the cluster endpoint, AWS region, VPC and subnet IDs, ECR URLs, GitHub ECR publishing role ARN, and EBS CSI role ARN. All outputs are metadata and contain no secret value. The complete public application address is the `cloudfront_https_url` output.

## CloudFront behavior

The default behavior allows `GET`, `HEAD`, `OPTIONS`, `PUT`, `POST`, `PATCH`, and `DELETE`. CloudFront's schema marks only `GET` and `HEAD` as cacheable methods, but the AWS-managed `CachingDisabled` policy uses zero TTLs so application responses are not retained. This avoids caching private or authenticated responses while the application is first placed behind the CDN.

The AWS-managed `AllViewerExceptHostHeader` origin request policy forwards all viewer query strings, cookies, the `Authorization` header, CORS preflight headers, and other viewer headers. It deliberately omits the original viewer `Host` header so CloudFront supplies the ALB origin host instead. `OPTIONS` reaches the Gateway like every other allowed method. Compression is enabled, IPv6 is enabled, and direct ALB access is unchanged.

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

An expected first plan creates the Secrets Manager metadata container, the scoped IAM role and inline read policy, the `external-secrets` namespace, the pinned operator Helm release, and updates the Argo CD Application dependency/revision. It destroys the old Terraform-managed `kubernetes_secret.app_secrets`. Review that removal carefully; do not run a normal deployment until the AWS secret is bootstrapped and the GitOps chart change is available on `main`.

## Destroy procedure

Confirm persistent-data and backup requirements, ensure both Terraform states are available, and run `bash destroy.sh` from the authenticated workstation. Do not remove the Ingress first. The script uses this order:

1. Initializes the isolated CloudFront root and, if its state contains resources, runs `terraform destroy`. The AWS provider disables and deletes only the state-managed distribution and waits for CloudFront; if stage 2 never ran, this is a no-op.
2. Selects the exact EKS cluster from base Terraform outputs, deletes the Argo CD Application so self-heal cannot recreate the Ingress, captures and validates the Ingress hostname, and deletes the namespace's Ingress.
3. Polls for the exact captured ALB DNS name for at most 30 attempts at 10-second intervals. It stops with an error instead of destroying the VPC if the ALB remains.
4. Performs the existing scoped controller-security-group cleanup, runs the base `terraform destroy`, and reports retained available EBS volumes.

CloudFront is never created or deleted with AWS CLI. The separate CloudFront state is intentionally destroyed before Kubernetes or ALB changes, works when the distribution or ALB is already absent, and keeps normal create/destroy operations idempotent. Do not discard either Terraform state before completing this sequence.

CloudFront creation and updates commonly need several minutes to propagate globally. Disabling and deleting a distribution can take 15-30 minutes or longer; Terraform waits for the AWS operation and must not be interrupted. These delays are expected and do not justify deleting the distribution outside Terraform.

The application secret sets `recovery_window_in_days = 0`. Terraform destroy therefore permanently deletes its container and versions instead of leaving the deterministic name scheduled for deletion, allowing a later course-environment apply to recreate the same name. This is intentionally irreversible: preserve any values needed for recovery through an approved secret backup/rotation procedure before destroy. AWS deletion is asynchronous, so an immediate recreate can still require a short retry with backoff.

## Troubleshooting

These commands expose status and metadata only:

```bash
terraform -chdir=terraform output -raw eks_cluster_name
terraform -chdir=terraform output -raw aws_region
terraform -chdir=terraform/cloudfront output
terraform -chdir=terraform/cloudfront state list
kubectl get application sports-store -n argocd
kubectl get ingress sports-store -n sports-store -o wide
kubectl describe ingress sports-store -n sports-store
kubectl get events -n sports-store --sort-by=.lastTimestamp
```

An absent CloudFront output means stage 2 has not successfully completed in the currently selected CloudFront state. An empty Ingress address means AWS Load Balancer Controller has not assigned the ALB yet; inspect the Ingress events and controller status without reading Kubernetes Secrets or AWS Secrets Manager values.

## Cost warning

EKS, the NAT Gateway, EC2 managed-node instances, EBS volumes, load balancers, CloudFront requests, CloudFront data transfer, and origin data transfer can incur charges. `PriceClass_100` limits edge locations to the lowest-cost CloudFront price class for this course environment, but it does not make requests or transfer free. A shared NAT Gateway reduces course-environment cost but is not highly available across availability zones. Monitor usage and destroy resources when they are no longer required.

At the configured desired capacity, expect one chargeable EKS control plane, one NAT Gateway, up to six `t3.micro` EC2 nodes and their root EBS volumes, ECR image storage, application EBS volumes such as the MongoDB PVC, one ALB, and one CloudFront distribution. Actual counts and charges can change through traffic, autoscaling, upgrades, retained volumes, and workload configuration.
