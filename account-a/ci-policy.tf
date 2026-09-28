# -----------------------------------------------------------------------------
# Task 4 - CI least-privilege policy (attached to the ci user ONLY)
#
# The CI pipeline may do exactly three things:
#   A. push a Docker image to ONE ECR repository
#   B. register a new task definition and deploy it to ONE ECS service
#   C. read build artifacts from ONE S3 bucket (read-only)
#
# No ECR/ECS/S3 infrastructure is created here: the targets are identified by
# name variables and their exact ARNs are built below. This keeps the exercise
# about the POLICY, not about provisioning an application.
#
# Resource "*" appears ONLY where the AWS authorization model offers no
# resource-level scoping:
#   ecr:GetAuthorizationToken   - account/registry-wide auth token, no resource type
#   ecs:RegisterTaskDefinition  - creates a NEW revision; no existing ARN to scope to
# Every other statement uses exact ARNs. See policies/README.md and NOTES.md Q7/Q8.
# -----------------------------------------------------------------------------

locals {
  ci_artifact_bucket_name = coalesce(var.ci_artifact_bucket_name, "${var.project_name}-artifacts-${var.account_a_id}")

  ci_ecr_repository_arn = "arn:aws:ecr:${var.aws_region}:${var.account_a_id}:repository/${var.ci_ecr_repository_name}"
  ci_ecs_service_arn    = "arn:aws:ecs:${var.aws_region}:${var.account_a_id}:service/${var.ci_ecs_cluster_name}/${var.ci_ecs_service_name}"
  ci_execution_role_arn = "${local.account_a_iam_prefix}:role/${var.ci_ecs_task_execution_role_name}"
  ci_task_role_arn      = "${local.account_a_iam_prefix}:role/${var.ci_ecs_task_role_name}"
  ci_artifact_bucket    = "arn:aws:s3:::${local.ci_artifact_bucket_name}"
}

data "aws_iam_policy_document" "ci" {
  # A. ECR authentication. GetAuthorizationToken has no resource type in the
  # IAM authorization model, so "*" is REQUIRED. The token alone grants nothing:
  # every push/pull call below is still checked against the repository ARN.
  statement {
    sid       = "EcrAuthTokenRequiresWildcard"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # A. ECR push to ONE repository.
  #   BatchCheckLayerAvailability - skip layers that already exist
  #   GetDownloadUrlForLayer      - read existing layers of THIS repo (docker/buildx
  #                                 reuse of base layers); read-only, same repo
  #   Initiate/Upload/Complete    - multipart layer upload
  #   PutImage                    - write the manifest / tag
  statement {
    sid    = "EcrPushToOneRepository"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [local.ci_ecr_repository_arn]
  }

  # B. Register a new task definition revision. Registration CREATES a new
  # resource (family:revision), so there is no existing ARN to scope to and
  # AWS requires "*" for this action.
  statement {
    sid       = "EcsRegisterTaskDefinitionRequiresWildcard"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  # B. Deploy to ONE service (UpdateService) and wait for stability (DescribeServices).
  statement {
    sid    = "EcsDeployOneService"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = [local.ci_ecs_service_arn]
  }

  # B. The new task definition references the execution role (pull image, write
  # logs) and the task role (app permissions). Registering it requires
  # iam:PassRole on exactly those two roles - and only towards ECS tasks.
  statement {
    sid     = "PassOnlyEcsTaskRolesToEcsTasks"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      local.ci_execution_role_arn,
      local.ci_task_role_arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # C. Artifacts - READ ONLY, ONE bucket.
  #   ListBucket applies to the BUCKET ARN; GetObject to OBJECT ARNs (bucket/*).
  statement {
    sid       = "ListArtifactBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.ci_artifact_bucket]
  }

  statement {
    sid       = "ReadArtifactObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.ci_artifact_bucket}/*"]
  }
}

resource "aws_iam_policy" "ci" {
  name        = "ci-least-privilege"
  description = "CI: push to one ECR repo, deploy one ECS service, read one artifact bucket (Task 4)."
  policy      = data.aws_iam_policy_document.ci.json
}

# Attached to the ci USER only - not group1, so engine does not inherit it.
resource "aws_iam_user_policy_attachment" "ci" {
  user       = aws_iam_user.this["ci"].name
  policy_arn = aws_iam_policy.ci.arn
}
