# ---------------------------------------------------------------------------
# Security Group for EKS Cluster
# ---------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster security group"
  vpc_id      = var.vpc_id

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

  # Auto Mode manages the AWS Load Balancer Controller
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

  # API auth mode required for Auto Mode access entries
  access_config {
    authentication_mode = "API"
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
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
