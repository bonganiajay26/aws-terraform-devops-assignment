# policies/

## ci-policy.json

A **reference rendering** of the `ci-least-privilege` policy that Terraform builds
in `account-a/ci-policy.tf` (`data "aws_iam_policy_document" "ci"`), using the
default placeholder values (account `000000000000`, region `us-east-1`).

- **Source of truth:** `account-a/ci-policy.tf`. This JSON is for review, AWS IAM
  Access Analyzer / policy simulator input, and documentation.
- **No drift:** `scripts/task4-local-poc.ps1` asserts that the policy rendered in
  the offline plan is semantically identical to this file (same statements, actions,
  resources and conditions). Update both together.

### Statement map

| Sid | Actions | Resource | Why this scope |
|---|---|---|---|
| `EcrAuthTokenRequiresWildcard` | `ecr:GetAuthorizationToken` | `*` | **AWS requires `*`**: the action has no resource type (it returns a registry-wide login token). The token grants nothing by itself; every image call is still authorized against the repository ARN. |
| `EcrPushToOneRepository` | `BatchCheckLayerAvailability`, `GetDownloadUrlForLayer`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage` | exact repository ARN | Minimum set for `docker push` (layer existence check, multipart upload, manifest). `GetDownloadUrlForLayer` is read-only on the same repository, used by docker/buildx when reusing existing layers. |
| `EcsRegisterTaskDefinitionRequiresWildcard` | `ecs:RegisterTaskDefinition` | `*` | **AWS requires `*`**: registering creates a new `family:revision`, so there is no existing ARN to scope to. |
| `EcsDeployOneService` | `ecs:UpdateService`, `ecs:DescribeServices` | exact service ARN (`service/<cluster>/<service>`) | Point the one service at the new revision, then poll until it is stable. |
| `PassOnlyEcsTaskRolesToEcsTasks` | `iam:PassRole` | exact execution-role and task-role ARNs, `iam:PassedToService = ecs-tasks.amazonaws.com` | The task definition references these roles. Without the condition the roles could be passed to other services (Lambda, EC2). Without exact ARNs *any* role, including admin roles, could be passed, which is a privilege escalation. |
| `ListArtifactBucket` | `s3:ListBucket` | bucket ARN | Bucket-level action. |
| `ReadArtifactObjects` | `s3:GetObject` | `bucket/*` | Object-level action, read only. |

### Deliberately NOT granted

See NOTES.md Q7/Q8. The short list: any `*` action wildcard, ECR pull-by-manifest
and repository management (`BatchGetImage`, `DescribeImages`, `Delete*`,
`SetRepositoryPolicy`, `CreateRepository`), ECS create/delete/run
(`CreateService`, `DeleteService`, `RunTask`, `DeregisterTaskDefinition`,
`DescribeTaskDefinition`), S3 writes/deletes, all IAM except the scoped `PassRole`,
`sts:AssumeRole`, and all managed "FullAccess" policies.
