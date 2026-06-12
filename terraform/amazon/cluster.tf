# ---------------------------------------------------------------------------
# Security Group for EKS Cluster
# ---------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster security group"
  vpc_id      = local.eks_vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-cluster-sg"
  })
}

# ---------------------------------------------------------------------------
# EKS Cluster with Auto Mode enabled
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  # Required for Auto Mode — prevents bootstrapping legacy self-managed add-ons
  bootstrap_self_managed_addons = false

  # Auto Mode compute configuration
  # node_pools lists built-in pools to activate. "system" covers kube-system
  # workloads. Custom ARM pool is applied separately via NodePool CRD.
  compute_config {
    enabled       = true
    node_pools    = ["system", "general-purpose"]
    node_role_arn = aws_iam_role.node.arn
  }

  # EKS Auto Mode requires compute_config.enabled,
  # kubernetes_network_config.elastic_load_balancing.enabled, and
  # storage_config.block_storage.enabled to ALL be the same value — you cannot
  # run Auto Mode compute/storage with load balancing disabled. Enabling the LB
  # *capability* provisions nothing on its own: an ELB is only ever created if a
  # Service of type LoadBalancer or an Ingress is deployed. This lab deploys
  # none and the ELB subnet tags are removed, so the cluster stays egress-only.
  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  # Auto Mode manages the EBS CSI driver
  storage_config {
    block_storage {
      enabled = true
    }
  }

  # API auth mode required for Auto Mode access entries.
  #
  # NOTE: the Terraform AWS provider defaults
  # bootstrap_cluster_creator_admin_permissions to FALSE (the underlying EKS
  # API defaults it to true — this is a known provider discrepancy). With
  # authentication_mode = "API" and no bootstrap, the principal running
  # `terraform apply` gets NO Kubernetes RBAC access, which would break the
  # kubectl apply in nodepool.tf. We grant access explicitly via the
  # aws_eks_access_entry resources below instead, which also avoids the
  # create-time-only / forces-replacement behavior of the bootstrap flag.
  access_config {
    authentication_mode = "API"
  }

  vpc_config {
    subnet_ids              = local.eks_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_eks,
    aws_iam_role_policy_attachment.cluster_compute,
    aws_iam_role_policy_attachment.cluster_block_storage,
    aws_iam_role_policy_attachment.cluster_load_balancing,
    aws_iam_role_policy_attachment.cluster_networking,
  ]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Cluster admin access for the Terraform caller
#
# Grants the IAM principal running `terraform apply` cluster-admin RBAC so the
# local-exec `kubectl apply` of the ARM NodePool (nodepool.tf) is authorized.
# This replaces relying on bootstrap_cluster_creator_admin_permissions.
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# EKS access entries require a PERMANENT IAM principal ARN (role or user). For an
# assumed role, get-caller-identity returns the STS *session* ARN
# (arn:aws:sts::ACCT:assumed-role/ROLE/SESSION), which the API rejects with
# "principalArn parameter format is not valid". So when the caller is an assumed
# role — including AWS SSO / Identity Center — we look the role up by name to get
# its real IAM role ARN. For SSO this resolves to the full path form,
# arn:aws:iam::ACCT:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_...,
# which access entries accept (unlike the old aws-auth ConfigMap, an access-entry
# role ARN may include a path). Set var.cluster_admin_principal_arn to override.
locals {
  caller_arn        = data.aws_caller_identity.current.arn
  caller_is_assumed = can(regex(":assumed-role/", local.caller_arn))
  caller_role_name  = local.caller_is_assumed ? regex(":assumed-role/([^/]+)/", local.caller_arn)[0] : ""

  admin_principal_arn = (
    var.cluster_admin_principal_arn != "" ? var.cluster_admin_principal_arn :
    local.caller_is_assumed ? data.aws_iam_role.caller[0].arn :
    local.caller_arn
  )
}

# Only looked up when auto-deriving from an assumed-role caller. GetRole accepts
# the friendly role name (last ARN segment) and returns the full ARN incl. path.
data "aws_iam_role" "caller" {
  count = var.cluster_admin_principal_arn == "" && local.caller_is_assumed ? 1 : 0
  name  = local.caller_role_name
}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.admin_principal_arn
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.admin_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
