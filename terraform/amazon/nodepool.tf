# ---------------------------------------------------------------------------
# ARM Graviton NodePool
#
# Uses null_resource + local-exec to apply the NodePool CRD after the cluster
# is live. kubernetes_manifest cannot be used here because the Kubernetes
# provider requires the cluster endpoint at init time — before the cluster
# exists — causing "no client config" on plan.
#
# Prerequisites on the machine running terraform apply:
#   - aws CLI authenticated with access to this cluster
#   - kubectl in PATH
# ---------------------------------------------------------------------------

locals {
  arm_nodepool_manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = var.arm_nodepool_name
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "eks.amazonaws.com"
            kind  = "NodeClass"
            name  = "default"
          }
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["arm64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = [var.arm_capacity_type]
            },
            {
              key      = "eks.amazonaws.com/instance-category"
              operator = "In"
              values   = var.arm_instance_categories
            },
            {
              key      = "eks.amazonaws.com/instance-generation"
              operator = "Gt"
              values   = [var.arm_instance_generation_min]
            },
          ]
          expireAfter = var.arm_node_expire_after
        }
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
        budgets = [
          { nodes = "10%" }
        ]
      }
      limits = {
        cpu    = var.arm_nodepool_cpu_limit
        memory = var.arm_nodepool_memory_limit
      }
    }
  }
}

# Write the NodePool manifest to a local file so local-exec can apply it cleanly
resource "local_file" "arm_nodepool_manifest" {
  filename        = "${path.module}/.terraform/arm-nodepool.yaml"
  content         = yamlencode(local.arm_nodepool_manifest)
  file_permission = "0600"
}

# Apply the NodePool after the cluster is active
# Triggers on any change to the manifest content so updates are re-applied
resource "null_resource" "arm_nodepool" {
  triggers = {
    cluster_name  = aws_eks_cluster.this.name
    manifest_hash = local_file.arm_nodepool_manifest.content
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${aws_eks_cluster.this.name} \
        --region ${var.aws_region} \
        --alias ${aws_eks_cluster.this.name}
      kubectl apply -f ${local_file.arm_nodepool_manifest.filename}
    EOT
  }

  depends_on = [
    aws_eks_cluster.this,
    local_file.arm_nodepool_manifest,
  ]
}

