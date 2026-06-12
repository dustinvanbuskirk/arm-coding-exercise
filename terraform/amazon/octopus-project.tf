# ── Project group ─────────────────────────────────────────────────────────────

resource "octopusdeploy_project_group" "tooling" {
  name        = var.kubearchinspect_project_group_name
  description = "Platform verification and tooling projects"
}

# ── Lifecycle ─────────────────────────────────────────────────────────────────
# Custom lifecycle with explicit, ordered phases:
#   1. Development — deployed AUTOMATICALLY as soon as a release is created
#   2. Staging     — deployed AUTOMATICALLY once Development succeeds
#   3. Production  — MANUAL only (optional target, never auto), so automatic
#                    promotion stops after Staging
# Defining ordered phases also fixes the ordering the built-in Default Lifecycle
# inherited from environment sort order. Retention blocks are intentionally
# omitted so the space-wide default retention applies (this sidesteps the
# deprecated release_retention_policy vs. *_with_strategy schema split).

resource "octopusdeploy_lifecycle" "kubearchinspect" {
  name        = var.octopus_lifecycle_name
  description = "Auto-deploy Development then Staging; Production is manual. Managed by Terraform."

  phase {
    name                         = var.environments[0] # Development
    automatic_deployment_targets = [octopusdeploy_environment.this[var.environments[0]].id]
    is_optional_phase            = false
  }

  phase {
    name                         = var.environments[1] # Staging
    automatic_deployment_targets = [octopusdeploy_environment.this[var.environments[1]].id]
    is_optional_phase            = false
  }

  # Production: listed only as an optional (manual) target — NOT in
  # automatic_deployment_targets — so it can be deployed by hand from the portal
  # but is never deployed automatically. is_optional_phase = true means a release
  # is considered complete after Staging without a Production deployment.
  phase {
    name                        = var.environments[2] # Production
    optional_deployment_targets = [octopusdeploy_environment.this[var.environments[2]].id]
    is_optional_phase           = true
  }

  depends_on = [octopusdeploy_environment.this]
}

# ── Project ───────────────────────────────────────────────────────────────────

resource "octopusdeploy_project" "kubearchinspect" {
  name             = var.kubearchinspect_project_name
  description      = "Verifies all running container images support arm64 (Graviton) via Arm's kubearchinspect, run as a Kubernetes Job."
  project_group_id = octopusdeploy_project_group.tooling.id
  lifecycle_id     = octopusdeploy_lifecycle.kubearchinspect.id

  is_disabled                       = false
  tenanted_deployment_participation = "Untenanted"

  depends_on = [
    octopusdeploy_project_group.tooling,
    octopusdeploy_environment.this,
    octopusdeploy_lifecycle.kubearchinspect,
  ]

  lifecycle {
    ignore_changes = [connectivity_policy]
  }
}

# ── Project variables ─────────────────────────────────────────────────────────
# Target Kubernetes namespace, derived from the environment name so each
# environment deploys into its own namespace:
#   Development -> development, Staging -> staging, Production -> production
# The deploy step and the verification runbook both reference #{Namespace}.
resource "octopusdeploy_variable" "namespace" {
  owner_id    = octopusdeploy_project.kubearchinspect.id
  name        = "Namespace"
  type        = "String"
  value       = "#{Octopus.Environment.Name | ToLower}"
  description = "Kubernetes namespace for the deploy/runbook, lowercased from the environment name."

  depends_on = [octopusdeploy_project.kubearchinspect]
}

# Default channel created with every project — handy to reference in pipelines.
data "octopusdeploy_channels" "default" {
  partial_name = "Default"
  project_id   = octopusdeploy_project.kubearchinspect.id
  skip         = 0
  take         = 1

  depends_on = [octopusdeploy_project.kubearchinspect]
}

output "kubearchinspect_project_id" {
  description = "Octopus project ID for kubearchinspect"
  value       = octopusdeploy_project.kubearchinspect.id
}

output "kubearchinspect_channel_id" {
  description = "Default channel ID for the kubearchinspect project"
  value       = data.octopusdeploy_channels.default.channels[0].id
}
