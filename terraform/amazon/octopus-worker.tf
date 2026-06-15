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
    # Ordering for destroy: the worker pod must be uninstalled BEFORE the worker
    # is deregistered and the pool deleted. With this dependency the reverse-order
    # teardown is: uninstall worker (helm_release) -> deregister worker
    # (null_resource) -> delete pool. cleanup itself depends on the pool, so the
    # chain is pool <- cleanup <- helm_release (no cycle).
    null_resource.cleanup_octopus_worker,
  ]
}

# ── Deregister the worker from Octopus on destroy ─────────────────────────────
# `helm uninstall` removes the worker pod but NOT its worker record in Octopus,
# so on destroy the worker pool can't be deleted while the worker
# (named after the cluster, e.g. dvb-eks-arm) is still assigned to it:
#   "The pool currently has one or more workers assigned to it ..."
# This deregisters the worker via the API before the pool is destroyed. It
# mirrors null_resource.cleanup_octopus_agent (workers live at /workers, not
# /machines). Requires curl + jq and $TF_VAR_octopus_api_key in the environment
# running `terraform destroy` (the same key you already export to run Terraform;
# it is deliberately NOT placed in triggers, which aren't treated as sensitive).
#
# ORDERING: depends_on the helm release (which itself depends on the pool via the
# data source), so on destroy this runs first — deregister worker -> uninstall
# worker pod -> delete pool — leaving the pool empty and deletable.
resource "null_resource" "cleanup_octopus_worker" {
  count = var.install_octopus_worker ? 1 : 0

  triggers = {
    worker_name = var.cluster_name
    space_id    = var.octopus_space_id
    octopus_url = var.octopus_server_url
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      # $TF_VAR_octopus_api_key is read from the environment, not from state.
      # $-prefixed names without braces are literal to Terraform and resolved by
      # the shell; $${self.triggers...} values are interpolated by Terraform.
      if [ -z "$TF_VAR_octopus_api_key" ]; then
        echo "TF_VAR_octopus_api_key is not set in the environment — skipping worker deregistration."
        echo "Either re-run destroy with 'export TF_VAR_octopus_api_key=API-...' or remove the"
        echo "worker '${self.triggers.worker_name}' manually in Octopus before deleting its pool."
        exit 0
      fi

      echo "Attempting to deregister worker '${self.triggers.worker_name}' from Octopus Deploy..."

      WORKER_ID=$(curl -s -H "X-Octopus-ApiKey: $TF_VAR_octopus_api_key" \
        "${self.triggers.octopus_url}/api/${self.triggers.space_id}/workers/all" | \
        jq -r '.[] | select(.Name=="${self.triggers.worker_name}") | .Id' | head -n 1)

      if [ -n "$WORKER_ID" ] && [ "$WORKER_ID" != "null" ]; then
        echo "Found worker ID: $WORKER_ID"
        curl -X DELETE -H "X-Octopus-ApiKey: $TF_VAR_octopus_api_key" \
          "${self.triggers.octopus_url}/api/${self.triggers.space_id}/workers/$WORKER_ID"
        echo "Worker deregistered"
      else
        echo "Worker not found (may already be deleted)"
      fi
    EOT
    on_failure = continue
  }

  depends_on = [octopusdeploy_static_worker_pool.this]
}

output "octopus_worker_pool_id" {
  description = "ID of the worker pool used by the Kubernetes worker"
  value       = var.install_octopus_worker ? local.worker_pool_id : ""
}
