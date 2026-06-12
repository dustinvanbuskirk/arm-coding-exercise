# ── AWS / cluster ─────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "dvb-eks-arm"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS API server endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_principal_arn" {
  description = <<-EOT
    IAM principal ARN to grant cluster-admin via an EKS access entry. Leave empty
    to auto-derive from the caller: an STS assumed-role/SSO session ARN is resolved
    to its underlying IAM role ARN (EKS access entries reject the STS session ARN).
    Set this explicitly if the auto-derived ARN isn't what you need — e.g. to force
    the path-stripped form arn:aws:iam::<acct>:role/AWSReservedSSO_<name>_<slug>.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all AWS resources"
  type        = map(string)
  default     = {}
}

# ── VPC (auto-created unless you bring your own) ───────────────────────────────

variable "create_vpc" {
  description = "Create a VPC + subnets. Set false and supply vpc_id/subnet_ids to bring your own."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "CIDR for the created VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "vpc_az_count" {
  description = "Number of AZs (and public/private subnet pairs) to create"
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all private subnets (cheaper) instead of one per AZ"
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "Existing VPC ID. Only used when create_vpc = false."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Existing subnet IDs (private recommended). Only used when create_vpc = false."
  type        = list(string)
  default     = []
}

# ── ARM Graviton NodePool ──────────────────────────────────────────────────────

variable "arm_nodepool_name" {
  type    = string
  default = "arm-graviton"
}

variable "arm_instance_categories" {
  type    = list(string)
  default = ["c", "m", "r"]
}

variable "arm_instance_generation_min" {
  type    = string
  default = "4"
}

variable "arm_capacity_type" {
  type    = string
  default = "on-demand"

  validation {
    condition     = contains(["on-demand", "spot"], var.arm_capacity_type)
    error_message = "arm_capacity_type must be either 'on-demand' or 'spot'."
  }
}

variable "arm_nodepool_cpu_limit" {
  type    = string
  default = "1000"
}

variable "arm_nodepool_memory_limit" {
  type    = string
  default = "1000Gi"
}

variable "arm_node_expire_after" {
  type    = string
  default = "336h"
}

# ── ECR ─────────────────────────────────────────────────────────────────────

variable "ecr_repository_name" {
  description = "ECR repository name; also used as the Octopus package/service id"
  type        = string
  default     = "kubearchinspect"
}

variable "ecr_image_tag_mutability" {
  type    = string
  default = "MUTABLE"
}

variable "ecr_scan_on_push" {
  type    = bool
  default = true
}

variable "ecr_force_delete" {
  description = "Allow Terraform to delete the ECR repo even if it still holds images (handy for demo teardown)"
  type        = bool
  default     = true
}

variable "create_ecr_push_user" {
  description = "Create a scoped IAM user + access key for CI to push to ECR. Disable to use GitHub OIDC instead."
  type        = bool
  default     = true
}

# ── GitHub ────────────────────────────────────────────────────────────────────

variable "github_owner" {
  description = "GitHub org/user that owns the forked repository"
  type        = string
}

variable "github_token" {
  description = "Fine-grained PAT scoped to the forked repository (Actions, Secrets, Variables: read/write)"
  type        = string
  sensitive   = true
}

variable "github_repository" {
  description = "Name of the forked repository to wire Actions vars/secrets into"
  type        = string
}

# ── Octopus connection ────────────────────────────────────────────────────────

variable "octopus_server_url" {
  type = string
}

variable "octopus_polling_url" {
  description = <<-EOT
    Polling Tentacle comms address for the agent/worker. Leave empty to
    auto-derive: Octopus Cloud serves polling comms on the instance URL with a
    "polling." prefix (https://polling.<name>.octopus.app), which is NOT the
    portal URL. Set explicitly for self-hosted servers (e.g. https://host:10943).
  EOT
  type        = string
  default     = ""
}

variable "arm_pod_node_selector" {
  description = <<-EOT
    Node selector applied to the Octopus agent/worker tentacle pods, pinning them
    to arm64 / Graviton nodes. The EKS Auto Mode general-purpose NodePool is
    amd64-only, so requiring arm64 routes scheduling to the custom Graviton
    NodePool. The ephemeral script pods are co-located on the tentacle's node by
    the chart's ReadWriteOnce mode, so they inherit arm64 automatically. Override
    to pin to a specific pool, e.g. { "karpenter.sh/nodepool" = "graviton-arm64" }.
  EOT
  type        = map(string)
  default     = { "kubernetes.io/arch" = "arm64" }
}

variable "agent_pod_security_context" {
  description = <<-EOT
    Pod-level securityContext applied to the Octopus agent/worker tentacle pods.
    Defaults to setting the SELinux type to spc_t (super-privileged container),
    which the tentacle needs to manage script pods and volume mounts on
    SELinux-enforcing nodes (e.g. Bottlerocket / AL2023 under EKS Auto Mode).
    Per the chart, leave runAsGroup/fsGroup unset (or 0). Set to {} to disable.
  EOT
  type        = any
  default     = { seLinuxOptions = { type = "spc_t" } }
}

variable "octopus_grpc_url" {
  description = "gRPC URL for the Kubernetes monitor (only needed if enabled)"
  type        = string
  default     = ""
}

variable "octopus_api_key" {
  type      = string
  sensitive = true
}

variable "octopus_space_id" {
  description = "Octopus space ID, e.g. Spaces-1"
  type        = string
}

variable "octopus_space_name" {
  description = "Octopus space display name"
  type        = string
  default     = "Default"
}

# ── EBS storage ───────────────────────────────────────────────────────────────

variable "cluster_is_auto_mode" {
  description = "true = Auto Mode (StorageClass only, no driver). false = standard EKS."
  type        = bool
  default     = true
}

variable "ebs_storage_class_name" {
  type    = string
  default = "ebs-gp3"
}

variable "ebs_set_default_storage_class" {
  type    = bool
  default = true
}

variable "install_ebs_csi_driver" {
  description = "Install aws-ebs-csi-driver. MUST stay false on Auto Mode."
  type        = bool
  default     = false
}

variable "ebs_csi_driver_chart_version" {
  type    = string
  default = "2.35.1"
}

# ── Octopus project (kubearchinspect) ──────────────────────────────────────────

variable "kubearchinspect_project_group_name" {
  type    = string
  default = "Platform Tooling"
}

variable "kubearchinspect_project_name" {
  type    = string
  default = "kubearchinspect"
}

# ── Octopus environments ────────────────────────────────────────────────────────

variable "environments" {
  type    = list(string)
  default = ["Development", "Staging", "Production"]
}

variable "octopus_lifecycle_name" {
  description = "Name of the custom Octopus lifecycle (auto Dev -> auto Staging -> manual Production) used by the project"
  type        = string
  default     = "kubearchinspect Auto Dev to Staging"
}

# ── Octopus Kubernetes Agent (deployment target) ────────────────────────────────

variable "install_octopus_agent" {
  type    = bool
  default = true
}

variable "octopus_agent_chart_version" {
  type    = string
  default = "3.5.0"
}

variable "octopus_agent_namespace" {
  type    = string
  default = "octopus-agent"
}

variable "octopus_agent_tags" {
  type    = list(string)
  default = ["kubernetes", "eks-arm"]
}

variable "octopus_agent_default_namespace" {
  type    = string
  default = "default"
}

variable "octopus_agent_storage_size" {
  type    = string
  default = "10Gi"
}

variable "octopus_agent_k8s_monitor_enabled" {
  type    = bool
  default = true
}

# ── Octopus Worker ──────────────────────────────────────────────────────────────

variable "install_octopus_worker" {
  type    = bool
  default = true
}

variable "create_worker_pool" {
  type    = bool
  default = true
}

variable "octopus_worker_pool_name" {
  type    = string
  default = "EKS ARM Workers"
}

variable "octopus_worker_namespace" {
  type    = string
  default = "octopus-workers"
}

variable "octopus_worker_storage_size" {
  type    = string
  default = "10Gi"
}
