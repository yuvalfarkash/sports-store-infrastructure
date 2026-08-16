locals {
  vpc_cni_configuration = {
    env = {
      ENABLE_PREFIX_DELEGATION = "false"
    }
  }

  managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      # These are static managed-node-group boundaries. No Cluster Autoscaler
      # or Karpenter component is installed by this configuration.
      min_size     = 2
      desired_size = 3
      max_size     = 4
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = "1.34"

  endpoint_public_access  = true
  endpoint_private_access = true
  enable_irsa             = true

  # CloudWatch collects control-plane logs. The separate GitOps-managed
  # Loki/Alloy stack collects namespace-scoped workload logs and events.
  enabled_log_types                      = ["api", "audit", "authenticator"]
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = 7

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent          = true
      before_compute       = true
      configuration_values = jsonencode(local.vpc_cni_configuration)
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.arn
    }
  }

  # The EKS-optimized AMI derives the supported t3.medium Pod limit from its
  # ENI/IP capacity. Prefix delegation remains disabled, so do not override
  # kubelet maxPods with a value that the VPC CNI cannot support.
  eks_managed_node_groups = local.managed_node_groups

  enable_cluster_creator_admin_permissions = true

  # Without this, the module's default node SG only opens node-to-node
  # traffic on ephemeral ports (1025-65535) plus a handful of specific
  # control-plane webhook ports - it has no rule for pod-to-pod traffic on
  # fixed ports like the gateway/frontend's 80, so cross-node requests
  # between pods time out silently (kubelet's own liveness/readiness probes
  # are always same-node, so pods still show Running/Ready and hide this).
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols (pod-to-pod across nodes)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  tags = local.common_tags
}
