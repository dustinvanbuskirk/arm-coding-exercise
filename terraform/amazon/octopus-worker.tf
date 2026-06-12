# ── Worker Pool ───────────────────────────────────────────────────────────────

resource "octopusdeploy_static_worker_pool" "this" {
  count       = var.install_octopus_worker && var.create_worker_pool ? 1 : 0
  name        = var.octopus_worker_pool_name
  description = "EKS ARM (Graviton) Kubernetes workers"
  sort_order  = 0
  is_default  = false

  lifecycle { ignore_changes = [description, sort_order] }
}

data "octopusdeploy_worker_pools" "selected" {
  count        = var.install_octopus_worker ? 1 : 0
  partial_name = var.octopus_worker_pool_name
  skip         = 0
  take         = 1

  depends_on = [octopusdeploy_static_worker_pool.this]
}

locals {
  worker_pool_id = var.install_octopus_worker ? data.octopusdeploy_worker_pools.selected[0].worker_pools[0].id : ""
}

# ── Octopus Kubernetes Agent — Worker mode ────────────────────────────────────

resource "helm_release" "octopus_worker" {
  count = var.install_octopus_worker ? 1 : 0

  name             = "octopus-worker"
  repository       = "oci://registry-1.docker.io/octopusdeploy"
  chart            = "kubernetes-agent"
  version          = var.octopus_agent_chart_version
  namespace        = kubernetes_namespace.octopus_workers[0].metadata[0].name
  create_namespace = false
  atomic           = false
  timeout          = 600

  values = [
    yamlencode({
      agent = {
        acceptEula           = "Y"
        name                 = var.cluster_name
        serverUrl            = var.octopus_server_url
        serverCommsAddresses = [local.octopus_polling_address]
        space                = var.octopus_space_name

        deploymentTarget = {
          enabled = false
        }

        worker = {
          enabled = true
          initial = {
            workerPools = [local.worker_pool_id]
          }
        }

        # Pin the tentacle (worker) pod onto arm64 / Graviton. Script pods are
        # co-located on this node by the chart's RWO mode (below), so they inherit
        # arm64 without a separate scriptPods affinity.
        nodeSelector = var.arm_pod_node_selector

        # Pod securityContext (SELinux spc_t by default) — see agent release.
        securityContext = var.agent_pod_security_context
      }

      # Direct EBS-backed workspace (ReadWriteOnce). On chart 3.x the tentacle is
      # a single pod and co-locates its script pods on its own node, so one RWO
      # EBS volume serves the worker and its script pods. No NFS.
      persistence = {
        accessModes      = ["ReadWriteOnce"]
        storageClassName = kubernetes_storage_class_v1.ebs_gp3.metadata[0].name
        size             = var.octopus_worker_storage_size
        nfs = {
          enabled = false
        }
      }

      serviceAccount = {
        create = false
        name   = kubernetes_service_account.octopus_worker[0].metadata[0].name
      }

      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { cpu = "500m", memory = "1Gi" }
      }
    })
  ]

  set_sensitive {
    name  = "agent.serverApiKey"
    value = var.octopus_api_key
  }

  depends_on = [
    data.octopusdeploy_worker_pools.selected,
    kubernetes_service_account.octopus_worker,
    kubernetes_storage_class_v1.ebs_gp3,
  ]
}

output "octopus_worker_pool_id" {
  description = "ID of the worker pool used by the Kubernetes worker"
  value       = var.install_octopus_worker ? local.worker_pool_id : ""
}
