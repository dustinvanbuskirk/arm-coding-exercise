# ---------------------------------------------------------------------------
# GitHub Actions wiring for the forked repository.
#
# These populate the vars/secrets the build-and-push workflow consumes. The
# JFrog inputs are replaced with ECR equivalents (see the updated workflow):
#   vars    : OCTOPUS_SERVICE, OCTOPUS_PROJECT, OCTOPUS_SPACE,
#             AWS_REGION, ECR_REGISTRY, ECR_REPOSITORY
#   secrets : AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#             OCTOPUS_SERVER_URL, OCTOPUS_API_KEY
#
# var.github_repository is the name of the repo created by the fork (under
# var.github_owner). The PAT only needs access to this one repository.
# ---------------------------------------------------------------------------

# ── Variables ──────────────────────────────────────────────────────────────

resource "github_actions_variable" "octopus_service" {
  repository    = var.github_repository
  variable_name = "OCTOPUS_SERVICE"
  value         = var.ecr_repository_name
}

resource "github_actions_variable" "octopus_project" {
  repository    = var.github_repository
  variable_name = "OCTOPUS_PROJECT"
  value         = var.kubearchinspect_project_name
}

resource "github_actions_variable" "octopus_space" {
  repository    = var.github_repository
  variable_name = "OCTOPUS_SPACE"
  value         = var.octopus_space_name
}

resource "github_actions_variable" "aws_region" {
  repository    = var.github_repository
  variable_name = "AWS_REGION"
  value         = var.aws_region
}

resource "github_actions_variable" "ecr_registry" {
  repository    = var.github_repository
  variable_name = "ECR_REGISTRY"
  value         = local.ecr_registry
}

resource "github_actions_variable" "ecr_repository" {
  repository    = var.github_repository
  variable_name = "ECR_REPOSITORY"
  value         = aws_ecr_repository.kubearchinspect.name
}

# ── Secrets ────────────────────────────────────────────────────────────────

resource "github_actions_secret" "aws_access_key_id" {
  count           = var.create_ecr_push_user ? 1 : 0
  repository      = var.github_repository
  secret_name     = "AWS_ACCESS_KEY_ID"
  value           = aws_iam_access_key.ecr_push[0].id
}

resource "github_actions_secret" "aws_secret_access_key" {
  count           = var.create_ecr_push_user ? 1 : 0
  repository      = var.github_repository
  secret_name     = "AWS_SECRET_ACCESS_KEY"
  value           = aws_iam_access_key.ecr_push[0].secret
}

resource "github_actions_secret" "octopus_server_url" {
  repository      = var.github_repository
  secret_name     = "OCTOPUS_SERVER_URL"
  value           = var.octopus_server_url
}

resource "github_actions_secret" "octopus_api_key" {
  repository      = var.github_repository
  secret_name     = "OCTOPUS_API_KEY"
  value           = var.octopus_api_key
}
