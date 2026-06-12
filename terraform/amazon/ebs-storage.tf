# ── EBS storage for the Octopus agent/worker shared filesystem ────────────────
#
# IMPORTANT — EKS Auto Mode vs standard EKS:
#
#   * Auto Mode (cluster_is_auto_mode = true, the default):
#       The EBS CSI controller is part of Auto Mode. You do NOT install a driver.
#       AWS does not ship a default StorageClass, so we create a gp3 one using the
#       Auto Mode provisioner `ebs.csi.eks.amazonaws.com`.
#
#   * Standard EKS (cluster_is_auto_mode = false):
#       The cluster needs the aws-ebs-csi-driver. Set install_ebs_csi_driver = true
#       to install it via Helm here, or (recommended) install it as an EKS managed
#       add-on in your cluster Terraform. The provisioner is `ebs.csi.aws.com`.
#       NOTE: the driver's controller ServiceAccount needs AWS permissions
#       (AmazonEBSCSIDriverPolicy) via IRSA/Pod Identity, otherwise volumes will
#       never provision. The EKS managed add-on wires this up for you; a bare Helm
#       install does not.
#
# Caveat for both paths: EBS volumes are ReadWriteOnce (single-node attach),
# unlike the chart's default in-cluster NFS server which is ReadWriteMany. The
# agent and its script pods must therefore stay co-located on one node/AZ. The
# chart handles this for single-replica agents; keep replicas at 1 for EBS.

locals {
  ebs_provisioner = var.cluster_is_auto_mode ? "ebs.csi.eks.amazonaws.com" : "ebs.csi.aws.com"
}

resource "kubernetes_storage_class_v1" "ebs_gp3" {
  metadata {
    name = var.ebs_storage_class_name
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = var.ebs_set_default_storage_class ? "true" : "false"
    }
  }

  storage_provisioner    = local.ebs_provisioner
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [
    helm_release.aws_ebs_csi_driver,
    aws_eks_access_policy_association.admin,
  ]
}

# Optional: standard-EKS driver install. Stays disabled on Auto Mode.
resource "helm_release" "aws_ebs_csi_driver" {
  count = var.install_ebs_csi_driver && !var.cluster_is_auto_mode ? 1 : 0

  name       = "aws-ebs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  version    = var.ebs_csi_driver_chart_version
  namespace  = "kube-system"

  create_namespace = false
  atomic           = false
  timeout          = 600

  set {
    name  = "controller.replicaCount"
    value = "1"
  }

  # The controller ServiceAccount needs IAM permissions to call EC2 EBS APIs.
  # Provide an IRSA role ARN here (role must have AmazonEBSCSIDriverPolicy), or
  # prefer the EKS managed add-on which configures this automatically.
  #
  # set {
  #   name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
  #   value = "arn:aws:iam::<account>:role/<ebs-csi-irsa-role>"
  # }
}

output "ebs_storage_class" {
  description = "Name of the gp3 StorageClass used by the agent and worker"
  value       = kubernetes_storage_class_v1.ebs_gp3.metadata[0].name
}
