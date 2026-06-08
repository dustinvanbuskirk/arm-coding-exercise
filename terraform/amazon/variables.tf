variable "aws_region" {
  description = "AWS region to deploy the EKS cluster"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "vpc_id" {
  description = "VPC ID where the cluster will be deployed"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the EKS cluster (recommend private subnets)"
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to access the EKS API server endpoint publicly"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ARM NodePool settings
variable "arm_nodepool_name" {
  description = "Name of the ARM Graviton NodePool"
  type        = string
  default     = "arm-graviton"
}

variable "arm_instance_categories" {
  description = "EC2 instance categories for the ARM NodePool (Graviton equivalents)"
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "arm_instance_generation_min" {
  description = "Minimum EC2 instance generation for the ARM NodePool"
  type        = string
  default     = "4"
}

variable "arm_capacity_type" {
  description = "Capacity type for ARM nodes: on-demand or spot"
  type        = string
  default     = "on-demand"

  validation {
    condition     = contains(["on-demand", "spot"], var.arm_capacity_type)
    error_message = "arm_capacity_type must be either 'on-demand' or 'spot'."
  }
}

variable "arm_nodepool_cpu_limit" {
  description = "Maximum total vCPUs across all ARM nodes in this NodePool"
  type        = string
  default     = "1000"
}

variable "arm_nodepool_memory_limit" {
  description = "Maximum total memory across all ARM nodes in this NodePool"
  type        = string
  default     = "1000Gi"
}

variable "arm_node_expire_after" {
  description = "Maximum lifetime of ARM nodes before forced recycling (e.g. 336h = 14 days)"
  type        = string
  default     = "336h"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
