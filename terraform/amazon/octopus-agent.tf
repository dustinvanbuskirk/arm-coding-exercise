# ── Octopus Kubernetes Agent — Deployment Target ──────────────────────────────
# Adapted from the local-k8s reference, but uses an EBS-backed StorageClass for
# the agent's shared filesystem instead of the in-cluster NFS server.

locals {
  agent_name = "${var.cluster_name}-agent"

  octopus_is_cloud = can(regex("\\.octopus\\.app", var.octopus_server_url))

  # Base comms host: explicit override if provided, otherwise the server URL.
  octopus_polling_base = var.octopus_polling_url != "" ? var.octopus_polling_url : var.octopus_server_url

  # Octopus Cloud serves polling Tentacle/agent comms on a DEDICATED host — the
  # instance URL with a "polling." prefix (https://polling.<name>.octopus.app),
  # never the portal/API URL. Handing the portal URL to the agent makes the
  # Tentacle's pre-registration connectivity check hit the web app and fail with
  # a 404 (exit code 100). So for *.octopus.app we force the "polling." prefix —
  # even when an override URL forgot it — while never double-prefixing. Anything
  # already prefixed, and all self-hosted URLs, pass through untouched; set
  # var.octopus_polling_url for a self-hosted comms endpoint (e.g. host:10943).
  octopus_polling_address = (
    local.octopus_is_cloud && !can(regex("//polling\\.", local.octopus_polling_base))
    ? replace(local.octopus_polling_base, "https://", "https://polling.")
    : local.octopus_polling_base
  )

  # gRPC endpoint for the Kubernetes Monitor (live object status). Octopus Server
  # serves the monitor's gRPC channel on port 8443. For Octopus Cloud this is the
  # instance host with a grpc:// scheme and :8443 (e.g.
  # grpc://<name>.octopus.app:8443), matching the wizard-generated Helm command.
  # Self-hosted servers must set var.octopus_grpc_url explicitly.
  octopus_grpc_address = (
    var.octopus_grpc_url != "" ? var.octopus_grpc_url :
    local.octopus_is_cloud ? format("grpc://%s:8443", replace(replace(var.octopus_server_url, "https://", ""), "/", "")) :
    ""
  )

  octopus_monitor_enabled = var.install_octopus_agent && var.octopus_agent_k8s_monitor_enabled

  # Base agent values, merged with monitor-only additions below.
  octopus_agent_values = merge(
    {
      agent = merge(
        {
          acceptEula           = "Y"
          name                 = local.agent_name
          serverUrl            = var.octopus_server_url
          serverCommsAddresses = [local.octopus_polling_address]
          space                = var.octopus_space_name

          deploymentTarget = {
            enabled = true
            initial = {
              environments     = var.environments
              tags             = var.octopus_agent_tags
              defaultNamespace = var.octopus_agent_default_namespace
            }
          }

          worker = {
            enabled = false
          }

          # Pin the tentacle (agent) pod onto arm64 / Graviton.
          nodeSelector = var.arm_pod_node_selector

          # Pod securityContext (SELinux spc_t by default) — required for the
          # tentacle to manage script pods / volume mounts on SELinux-enforcing nodes.
          securityContext = var.agent_pod_security_context
        },
        # When the monitor is enabled the deployment target is pre-created in
        # Terraform (so the monitor resource can reference its machine_id without
        # a dependency cycle). The agent then adopts that target identity via the
        # polling subscription id (paired with agent.certificate in set_sensitive).
        local.octopus_monitor_enabled ? {
          serverSubscriptionId = octopusdeploy_polling_subscription_id.agent[0].polling_uri
        } : {}
      )

      # Direct EBS-backed workspace. EBS is block storage (ReadWriteOnce), and on
      # chart 3.x ReadWriteOnce is the supported default: the agent co-locates its
      # script pods on its own node so a single RWO volume serves both. No NFS.
      persistence = {
        accessModes      = ["ReadWriteOnce"]
        storageClassName = kubernetes_storage_class_v1.ebs_gp3.metadata[0].name
        size             = var.octopus_agent_storage_size
        nfs = {
          enabled = false
        }
      }

      serviceAccount = {
        create = false
        name   = kubernetes_service_account.octopus_agent[0].metadata[0].name
      }

      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { cpu = "500m", memory = "1Gi" }
      }
    },
    # Kubernetes Monitor (live object status). Registration is performed by the
    # octopusdeploy_kubernetes_monitor resource using the provider's API key, so
    # the chart must NOT self-register (register = false) — that avoids the short-
    # lived serverAccessToken the wizard command uses. The chart is handed the
    # monitor's installation id, the server's gRPC URL, and (in set_sensitive) the
    # registration's authentication token + certificate thumbprint.
    local.octopus_monitor_enabled ? {
      kubernetesMonitor = {
        enabled = true
        registration = {
          register = false
        }
        monitor = {
          serverGrpcUrl    = local.octopus_grpc_address
          installationId   = random_uuid.monitor_installation[0].result
          serverThumbprint = octopusdeploy_kubernetes_monitor.agent[0].certificate_thumbprint
        }
      }
    } : {}
  )
}

resource "helm_release" "octopus_agent" {
  count = var.install_octopus_agent ? 1 : 0

  name             = local.agent_name
  repository       = "oci://registry-1.docker.io/octopusdeploy"
  chart            = "kubernetes-agent"
  version          = var.octopus_agent_chart_version
  namespace        = kubernetes_namespace.octopus_agent[0].metadata[0].name
  create_namespace = false
  atomic           = false
  timeout          = 600

  values = [yamlencode(local.octopus_agent_values)]

  # Sensitive values passed separately so they don't land in the values yaml.
  set_sensitive {
    name  = "agent.serverApiKey"
    value = var.octopus_api_key
  }

  # When the monitor is enabled, the agent adopts the Terraform-created target's
  # tentacle certificate, and the monitor sub-chart needs its registration token.
  dynamic "set_sensitive" {
    for_each = local.octopus_monitor_enabled ? [1] : []
    content {
      name  = "agent.certificate"
      value = octopusdeploy_tentacle_certificate.agent[0].base64
    }
  }

  dynamic "set_sensitive" {
    for_each = local.octopus_monitor_enabled ? [1] : []
    content {
      name  = "kubernetesMonitor.monitor.authenticationToken"
      value = octopusdeploy_kubernetes_monitor.agent[0].authentication_token
    }
  }

  depends_on = [
    kubernetes_service_account.octopus_agent,
    kubernetes_storage_class_v1.ebs_gp3,
    octopusdeploy_environment.this,
  ]
}

# ── Kubernetes Monitor (live object status) ───────────────────────────────────
# These resources only exist when var.octopus_agent_k8s_monitor_enabled = true.
# They pre-create the agent's deployment target and register the monitor through
# the Octopus API (provider API key), so the Helm chart can run the monitor
# without the wizard's short-lived serverAccessToken.

# Stable polling subscription id + tentacle certificate that identify the agent's
# deployment target. Pre-creating them lets Terraform create the target record
# (below) before the agent connects, breaking the monitor <-> target cycle.
resource "octopusdeploy_polling_subscription_id" "agent" {
  count = local.octopus_monitor_enabled ? 1 : 0
}

resource "octopusdeploy_tentacle_certificate" "agent" {
  count = local.octopus_monitor_enabled ? 1 : 0
}

# The deployment target record. The agent's Helm install adopts this identity via
# agent.serverSubscriptionId + agent.certificate, so no duplicate target is made
# — provided any previously self-registered target of the same name is removed
# first (delete it under Infrastructure -> Deployment Targets before enabling).
resource "octopusdeploy_kubernetes_agent_deployment_target" "agent" {
  count        = local.octopus_monitor_enabled ? 1 : 0
  space_id     = var.octopus_space_id
  name         = local.agent_name
  environments = [for e in var.environments : octopusdeploy_environment.this[e].id]
  roles        = var.octopus_agent_tags
  thumbprint   = octopusdeploy_tentacle_certificate.agent[0].thumbprint
  uri          = octopusdeploy_polling_subscription_id.agent[0].polling_uri

  depends_on = [octopusdeploy_environment.this]
}

# Per-installation id for the monitor (stable across applies).
resource "random_uuid" "monitor_installation" {
  count = local.octopus_monitor_enabled ? 1 : 0
}

# Registers the monitor against the deployment target using the provider's API
# key, and returns the authentication token + certificate thumbprint the chart's
# monitor sub-chart consumes (with registration.register = false).
resource "octopusdeploy_kubernetes_monitor" "agent" {
  count           = local.octopus_monitor_enabled ? 1 : 0
  space_id        = var.octopus_space_id
  installation_id = random_uuid.monitor_installation[0].result
  machine_id      = octopusdeploy_kubernetes_agent_deployment_target.agent[0].id
}

# ── Deregister the deployment target from Octopus on destroy ───────────────────
# Requires curl + jq on the machine running terraform destroy.
#
# SECURITY: the Octopus API key is deliberately NOT stored in triggers. Unlike
# the provider config and the agent's set_sensitive value, trigger values are
# not treated as sensitive — they appear in plan output and sit readable in
# state. A destroy-time provisioner can only reference self/count/each (never
# var.*), so the non-secret values stay in triggers and the key is read from the
# environment at destroy time instead: it's the same TF_VAR_octopus_api_key you
# export to run Terraform, so it's already present in the shell. The key never
# enters triggers, plan output, or state via this resource.

resource "null_resource" "cleanup_octopus_agent" {
  count = var.install_octopus_agent ? 1 : 0

  triggers = {
    agent_name  = local.agent_name
    space_id    = var.octopus_space_id
    octopus_url = var.octopus_server_url
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      # $TF_VAR_octopus_api_key is read from the environment, not from state.
      # $-prefixed names without braces are literal to Terraform and resolved by
      # the shell; $${...self...} values are interpolated by Terraform.
      if [ -z "$TF_VAR_octopus_api_key" ]; then
        echo "TF_VAR_octopus_api_key is not set in the environment — skipping agent deregistration."
        echo "Either re-run destroy with 'export TF_VAR_octopus_api_key=API-...' or remove the"
        echo "deployment target '${self.triggers.agent_name}' manually in Octopus."
        exit 0
      fi

      echo "Attempting to deregister agent '${self.triggers.agent_name}' from Octopus Deploy..."

      MACHINE_ID=$(curl -s -H "X-Octopus-ApiKey: $TF_VAR_octopus_api_key" \
        "${self.triggers.octopus_url}/api/${self.triggers.space_id}/machines/all" | \
        jq -r '.[] | select(.Name=="${self.triggers.agent_name}") | .Id' | head -n 1)

      if [ -n "$MACHINE_ID" ] && [ "$MACHINE_ID" != "null" ]; then
        echo "Found deployment target ID: $MACHINE_ID"
        curl -X DELETE -H "X-Octopus-ApiKey: $TF_VAR_octopus_api_key" \
          "${self.triggers.octopus_url}/api/${self.triggers.space_id}/machines/$MACHINE_ID"
        echo "Deployment target deregistered"
      else
        echo "Deployment target not found (may already be deleted)"
      fi
    EOT
    on_failure = continue
  }

  depends_on = [helm_release.octopus_agent]
}
