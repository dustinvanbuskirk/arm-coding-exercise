# ---------------------------------------------------------------------------
# ECR repository for the kubearchinspect image (replaces the JFrog feed).
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "kubearchinspect" {
  name                 = var.ecr_repository_name
  image_tag_mutability = var.ecr_image_tag_mutability
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = var.ecr_scan_on_push
  }

  tags = var.tags
}

# Keep only the most recent N images to control storage cost.
resource "aws_ecr_lifecycle_policy" "kubearchinspect" {
  repository = aws_ecr_repository.kubearchinspect.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images"
      selection = {
        tagStatus   = "untagged"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# Scoped push user for CI.
#
# SECURITY NOTE: this creates a long-lived IAM access key, and its secret is
# stored in Terraform state and pushed to GitHub as an Actions secret. The
# workflow already declares `permissions: id-token: write`, so the more secure
# option is GitHub OIDC -> an IAM role with no static keys. This user path is
# provided because it was requested and is simplest to bootstrap; flip
# create_ecr_push_user = false and wire an OIDC role when you're ready.
# ---------------------------------------------------------------------------

resource "aws_iam_user" "ecr_push" {
  count = var.create_ecr_push_user ? 1 : 0
  name  = "${var.ecr_repository_name}-ci-push"
  tags  = var.tags
}

resource "aws_iam_user_policy" "ecr_push" {
  count = var.create_ecr_push_user ? 1 : 0
  name  = "${var.ecr_repository_name}-ecr-push"
  user  = aws_iam_user.ecr_push[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Token endpoint does not support resource-level scoping.
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Push/pull + enumerate, limited to THIS repository only. The describe/
        # list actions are what the Octopus ECR image feed uses to surface
        # available image versions when creating a release.
        Sid    = "EcrPushPullThisRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:ListImages"
        ]
        Resource = [
          aws_ecr_repository.kubearchinspect.arn,
        ]
      }
    ]
  })
}

resource "aws_iam_access_key" "ecr_push" {
  count = var.create_ecr_push_user ? 1 : 0
  user  = aws_iam_user.ecr_push[0].name
}

# ---------------------------------------------------------------------------
# Outputs / convenience locals
# ---------------------------------------------------------------------------

locals {
  # e.g. 336151728602.dkr.ecr.us-east-1.amazonaws.com
  ecr_registry = split("/", aws_ecr_repository.kubearchinspect.repository_url)[0]
}

output "ecr_repository_url" {
  description = "Full ECR repository URL for the kubearchinspect image"
  value       = aws_ecr_repository.kubearchinspect.repository_url
}

output "ecr_registry" {
  description = "ECR registry host"
  value       = local.ecr_registry
}

output "ecr_push_access_key_id" {
  description = "Access key ID for the scoped ECR push user"
  value       = var.create_ecr_push_user ? aws_iam_access_key.ecr_push[0].id : ""
}

output "ecr_push_secret_access_key" {
  description = "Secret access key for the scoped ECR push user"
  value       = var.create_ecr_push_user ? aws_iam_access_key.ecr_push[0].secret : ""
  sensitive   = true
}
