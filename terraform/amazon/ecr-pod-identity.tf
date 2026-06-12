# ---------------------------------------------------------------------------
# ECR registry auth for kubearchinspect (EKS Pod Identity)
#
# kubearchinspect queries each running image's manifest DIRECTLY from its
# registry (via the containers/image library) to decide arm64 support, and reads
# registry credentials only from $HOME/.docker/config.json. It does NOT use the
# kubelet's image-pull path or Kubernetes imagePullSecrets. So even though the
# Auto Mode node role lets the kubelet PULL private ECR images, the
# kubearchinspect process itself reports an "Authentication Error" on private
# ECR images unless it is handed a docker config with a valid token.
#
# This grants the kubearchinspect ServiceAccount (in each environment namespace)
# an IAM role with ECR read access via EKS Pod Identity. Auto Mode nodes have
# Pod Identity support built in, so no eks-pod-identity-agent addon is required.
# An init container in the Job (see kubearchinspect/templates/job.yaml and the
# verification runbook) then uses these credentials to mint a fresh ECR token
# and write the docker config kubearchinspect reads.
#
# Both the deploy-time chart Job and the runbook Job run as this same SA, so one
# association per namespace covers both.
# ---------------------------------------------------------------------------

variable "enable_kubearchinspect_ecr_auth" {
  description = "Grant the kubearchinspect ServiceAccount ECR read via EKS Pod Identity so it can query private ECR image manifests."
  type        = bool
  default     = true
}

variable "kubearchinspect_aws_cli_image" {
  description = "AWS CLI image (arm64-capable) used by the Job init container to mint a short-lived ECR token."
  type        = string
  default     = "public.ecr.aws/aws-cli/aws-cli:latest"
}

locals {
  kubearchinspect_sa_name     = "kubearchinspect"
  kubearchinspect_ecr_auth_on = var.enable_kubearchinspect_ecr_auth
}

data "aws_iam_policy_document" "kubearchinspect_ecr_trust" {
  count = local.kubearchinspect_ecr_auth_on ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kubearchinspect_ecr_read" {
  count              = local.kubearchinspect_ecr_auth_on ? 1 : 0
  name               = "${var.cluster_name}-kubearchinspect-ecr-read"
  assume_role_policy = data.aws_iam_policy_document.kubearchinspect_ecr_trust[0].json
  tags               = var.tags
}

# AmazonEC2ContainerRegistryReadOnly grants ecr:GetAuthorizationToken (needed by
# `aws ecr get-login-password`) plus the read actions (BatchGetImage,
# GetDownloadUrlForLayer, DescribeImages, ...) the minted token is authorized
# against when kubearchinspect pulls a manifest. ECR auth tokens are
# account-scoped, so read-on-all-repos is appropriate for a cluster-wide scan.
resource "aws_iam_role_policy_attachment" "kubearchinspect_ecr_read" {
  count      = local.kubearchinspect_ecr_auth_on ? 1 : 0
  role       = aws_iam_role.kubearchinspect_ecr_read[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# One association per environment namespace -> the kubearchinspect SA. The SA is
# created later by the Helm deploy; the association only needs the namespace
# (pre-created in namespaces.tf) and the SA name to exist as strings.
resource "aws_eks_pod_identity_association" "kubearchinspect_ecr" {
  for_each = local.kubearchinspect_ecr_auth_on ? kubernetes_namespace.environment : {}

  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.value.metadata[0].name
  service_account = local.kubearchinspect_sa_name
  role_arn        = aws_iam_role.kubearchinspect_ecr_read[0].arn

  tags = var.tags
}

output "kubearchinspect_ecr_auth_role_arn" {
  description = "IAM role ARN the kubearchinspect SA assumes (via Pod Identity) to read ECR"
  value       = local.kubearchinspect_ecr_auth_on ? aws_iam_role.kubearchinspect_ecr_read[0].arn : ""
}
