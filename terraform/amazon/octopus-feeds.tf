# ---------------------------------------------------------------------------
# Octopus package feeds.
#
#   image feed   -> the kubearchinspect container IMAGE, stored in ECR. The
#                   AWS ECR feed type calls ecr:GetAuthorizationToken and
#                   refreshes the ephemeral ECR token (~12h) automatically, so
#                   a static-cred feed isn't needed. Defined for visibility and
#                   for image-based release triggers; the deploy injects the
#                   image via Helm values (octopus-process.tf), and the kubelet
#                   pulls it directly from ECR.
#
#   built-in feed -> the kubearchinspect HELM CHART. The CI workflow runs
#                   `octopus package upload` to push the packaged chart .tgz to
#                   Octopus's built-in feed. The Helm step then acquires it ON
#                   THE AGENT over the Tentacle protocol — no docker CLI, no
#                   Server-side acquisition. (An ECR/OCI chart can only be
#                   acquired through a container feed, which always uses the
#                   docker-based downloader the agent's script pod lacks; and
#                   Octopus has no OCI/Helm feed type for the Helm step yet.)
#
# Auth for the image feed: static IAM access/secret keys from the scoped CI
# push user (ecr.tf). For a secretless setup this resource also supports an
# `oidc_authentication { role_arn = ... }` block — see the provider docs.
# ---------------------------------------------------------------------------

# Credentials for the image feed. Default to the CI push user created in ecr.tf;
# override these when create_ecr_push_user = false.
variable "ecr_feed_access_key" {
  description = "AWS access key for the Octopus ECR image feed (used when create_ecr_push_user = false)"
  type        = string
  default     = ""
}

variable "ecr_feed_secret_key" {
  description = "AWS secret key for the Octopus ECR image feed (used when create_ecr_push_user = false)"
  type        = string
  sensitive   = true
  default     = ""
}

# The built-in package feed's ID is only the literal "feeds-builtin" in the
# DEFAULT space. In any other space (this repo uses "ARM-Testing") it has a
# space-scoped ID like "Feeds-NNN", so hardcoding "feeds-builtin" fails the
# deployment process with: Feed 'feeds-builtin' not found. Resolve the real ID
# from the API for whichever space the provider is pointed at.
data "octopusdeploy_feeds" "builtin" {
  feed_type = "BuiltIn"
}

locals {
  feed_access_key = var.create_ecr_push_user ? aws_iam_access_key.ecr_push[0].id : var.ecr_feed_access_key
  feed_secret_key = var.create_ecr_push_user ? aws_iam_access_key.ecr_push[0].secret : var.ecr_feed_secret_key

  # The single built-in feed in the configured space. Use the nested feed's
  # `.id` (not the data source's own `.id`, which renders a non-ID value).
  builtin_feed_id = data.octopusdeploy_feeds.builtin.feeds[0].id
}

resource "octopusdeploy_aws_elastic_container_registry" "image" {
  name       = "${var.ecr_repository_name} image (ECR)"
  region     = var.aws_region
  access_key = local.feed_access_key
  secret_key = local.feed_secret_key
}

locals {
  image_feed_id = octopusdeploy_aws_elastic_container_registry.image.id
}

output "octopus_image_feed_id" {
  description = "Octopus feed ID for the kubearchinspect image"
  value       = local.image_feed_id
}

output "octopus_chart_feed_id" {
  description = "Octopus feed ID used for the kubearchinspect Helm chart (built-in feed)"
  value       = local.builtin_feed_id
}
