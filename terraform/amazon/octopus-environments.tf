# Development, Staging, Production (from var.environments).
# allow_dynamic_infrastructure = true lets the Kubernetes Agent register itself
# as a deployment target into these environments.
#
# ORDERING — why sort_order is intentionally NOT set:
# Octopus assigns an environment's SortOrder by server-side insertion order and
# ignores the value sent on the create request. Because for_each creates all
# environments in parallel, setting sort_order made the provider return a value
# different from the one planned (e.g. Development planned 0, server assigned 2),
# which fails with "Provider produced inconsistent result after apply".
#
# This is purely cosmetic: deployment *progression* is driven by the ordered
# phases of octopusdeploy_lifecycle.kubearchinspect (Development -> Staging ->
# Production), not by the environment list order. So we let Octopus assign
# sort_order and ignore it on subsequent plans.

resource "octopusdeploy_environment" "this" {
  for_each = toset(var.environments)

  name                         = each.value
  description                  = "${each.value} — managed by Terraform"
  allow_dynamic_infrastructure = true
  use_guided_failure           = false

  # Server-assigned; never reconcile it (see header).
  lifecycle {
    ignore_changes = [sort_order]
  }
}

output "octopus_environment_ids" {
  description = "Octopus environment IDs"
  value       = { for k, v in octopusdeploy_environment.this : k => v.id }
}

# ── Order the environments in the Octopus UI ──────────────────────────────────
# Octopus manages an environment's SortOrder server-side. On create, a SortOrder
# of 0 means "append to the end of the list", so the order can't be set reliably
# at create time — that is what produced the out-of-order list (Staging,
# Production, Development) and the earlier "inconsistent result after apply" when
# sort_order was set explicitly. The supported way to order environments is the
# dedicated sort-order endpoint, which takes an array of EVERY environment ID in
# the space in the desired order. We call it once the environments exist and
# re-run whenever the desired order changes.
#
# Requires curl + jq on the machine running terraform (same as the agent-cleanup
# provisioner). The API key is read from $TF_VAR_octopus_api_key (already in your
# shell to run Terraform) and is never written to triggers or state.
resource "null_resource" "environment_sort_order" {
  triggers = {
    # Desired order = var.environments order, mapped to the created IDs.
    ordered_ids = join(",", [for e in var.environments : octopusdeploy_environment.this[e].id])
    space_id    = var.octopus_space_id
    octopus_url = var.octopus_server_url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      if [ -z "$TF_VAR_octopus_api_key" ]; then
        echo "TF_VAR_octopus_api_key is not set — skipping environment sort-order update."
        echo "Re-run with 'export TF_VAR_octopus_api_key=API-...' to order the environments."
        exit 0
      fi

      BASE="${self.triggers.octopus_url}/api/${self.triggers.space_id}"
      DESIRED="${self.triggers.ordered_ids}"

      # The endpoint requires EVERY environment ID in the space. Put our managed
      # environments first (in the desired order), then append any others so the
      # request is complete.
      ALL_JSON=$(curl -sf -H "X-Octopus-ApiKey: $TF_VAR_octopus_api_key" "$BASE/environments/all")
      ORDERED=$(echo "$ALL_JSON" | jq -c --arg desired "$DESIRED" \
        '($desired | split(",")) as $d | [.[].Id] as $all | $d + ($all - $d)')

      echo "Setting Octopus environment order to: $ORDERED"
      curl -sf -X PUT \
        -H "X-Octopus-ApiKey: $TF_VAR_octopus_api_key" \
        -H "Content-Type: application/json" \
        "$BASE/environments/sortorder" \
        -d "$ORDERED" >/dev/null
      echo "Environment sort order updated."
    EOT
  }

  depends_on = [octopusdeploy_environment.this]
}
