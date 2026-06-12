# ---------------------------------------------------------------------------
# Deployment process for the kubearchinspect project.
#
# A single "Upgrade a Helm Chart" step that:
#   - pulls the chart from the Octopus built-in feed. The CI workflow packages
#     the chart and `octopus package upload`s the .tgz to the built-in feed at
#     the same version as the image, so the release version drives the chart.
#   - sets image.repository / image.tag via inline YAML values. The image still
#     lives in ECR and is pulled by the kubelet; only the *chart* moved feeds.
#     image.tag = #{Octopus.Release.Number}.
#   - runs on the Kubernetes Agent target (matched by its target tags).
#
# WHY THE BUILT-IN FEED (and not the ECR chart feed): an AWS ECR feed always
# acquires via Octopus's DockerImagePackageDownloader, which shells out to the
# `docker` CLI. On a Kubernetes Agent the step runs in a script pod whose image
# (octopusdeploy/worker-tools) ships helm + kubectl but NOT docker, so agent-
# side acquisition fails with "docker: command not found". Octopus has no
# OCI/Helm feed type for the Helm step (roadmap only), so the only way to keep
# acquisition on the agent — no docker, no Server — is to deliver the chart
# through a non-docker feed. The built-in feed transfers the package over the
# Tentacle protocol, so acquisition_location = "ExecutionTarget" works in-
# cluster with no docker and without the Server running the step.
#
# NOTE: the v1 provider does not strongly-type Helm actions — the keys below are
# the raw Octopus action properties (confirmed against Octopus's own config-as-
# code example for Octopus.HelmChartUpgrade). If you tweak the step in the UI,
# re-export to confirm any added property keys.
# ---------------------------------------------------------------------------

resource "octopusdeploy_process" "kubearchinspect" {
  project_id = octopusdeploy_project.kubearchinspect.id
}

resource "octopusdeploy_process_step" "helm_upgrade" {
  process_id = octopusdeploy_process.kubearchinspect.id
  name       = "Upgrade kubearchinspect Helm chart"
  type       = "Octopus.HelmChartUpgrade"

  # Run on the Kubernetes Agent deployment target(s) matched by these tags.
  properties = {
    "Octopus.Action.TargetRoles" = join(",", var.octopus_agent_tags)
  }

  # Acquire the chart on the EXECUTION TARGET (the Kubernetes Agent), in-cluster.
  # The built-in feed delivers the package over the Tentacle protocol — no docker
  # CLI and no Server-side acquisition involved. package_id is the Helm chart name
  # (Chart.yaml `name:`), which is what `octopus package upload` registers it as.
  primary_package = {
    package_id           = var.ecr_repository_name
    feed_id              = local.builtin_feed_id
    acquisition_location = "ExecutionTarget"
  }

  execution_properties = {
    "Octopus.Action.RunOnServer"        = "False"
    "Octopus.Action.Helm.ClientVersion" = "V3"
    "Octopus.Action.Helm.ReleaseName"   = var.kubearchinspect_project_name
    "Octopus.Action.Helm.Namespace"     = "#{Namespace}"
    "Octopus.Action.Helm.ResetValues"   = "True"

    # Inline values. ${...} is interpolated by Terraform (the ECR repo URL,
    # registry host and region); #{...} stays literal for Octopus to resolve at
    # deploy time. ecrAuth lets kubearchinspect query the private ECR image
    # manifests (its own image and any other ECR images in the cluster) using a
    # token minted from the SA's Pod Identity role (see ecr-pod-identity.tf).
    "Octopus.Action.Helm.YamlValues" = <<-EOT
      image:
        repository: ${aws_ecr_repository.kubearchinspect.repository_url}
        tag: "#{Octopus.Release.Number}"
      ecrAuth:
        enabled: ${var.enable_kubearchinspect_ecr_auth}
        registry: ${local.ecr_registry}
        region: ${var.aws_region}
    EOT
  }

  depends_on = [
    octopusdeploy_project.kubearchinspect,
    octopusdeploy_variable.namespace,
  ]
}

output "kubearchinspect_process_id" {
  description = "Octopus deployment process ID for kubearchinspect"
  value       = octopusdeploy_process.kubearchinspect.id
}
