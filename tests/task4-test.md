# Task 4 - CI Least-Privilege Policy - Test Procedure

- **Phase 1 - LOCAL** (done, no AWS account): `scripts/task4-local-poc.ps1`
- **Phase 2 - REAL AWS** (pending): section 2

Scope: this task implements the **policy** only. The ECR repository, ECS
cluster/service, the two ECS task roles, and the artifact bucket are **not**
created by this repository. They are identified by name variables (`ci_*`) and
their exact ARNs are built in `account-a/ci-policy.tf`.

---

## 1. LOCAL POC (no AWS)

```powershell
Set-Location C:\work\aws-terraform-devops-assignment
powershell -ExecutionPolicy Bypass -File .\scripts\task4-local-poc.ps1
```

| # | Check | Evidence source |
|---|---|---|
| L1 | Baseline fmt / init / validate / hygiene | `validate-local.ps1` |
| L2 | Terraform policy structure: customer-managed `ci-least-privilege`, attached to user **ci** only (not group1/engine), the attachment references `aws_iam_policy.ci` | plan JSON + configuration |
| L3 | Rendered policy JSON: 7 Allow statements; exact repository, service, role and bucket ARNs; `iam:PassedToService = ecs-tasks.amazonaws.com`; **semantically identical to `policies/ci-policy.json`** | rendered policy |
| L4 | Wildcard-resource exceptions: `Resource "*"` only in `EcrAuthTokenRequiresWildcard` and `EcsRegisterTaskDefinitionRequiresWildcard`, each with a single action; no action wildcards, no partial-wildcard ARNs except `bucket/*`, no NotAction/NotResource | rendered policy |
| L5 | Broad managed policies absent (AdministratorAccess, PowerUserAccess, *FullAccess, ECR PowerUser) | plan + configuration |
| L6 | 35 deliberately excluded actions absent; no IAM action except scoped `iam:PassRole` | rendered policy |
| L7 | Access matrix A-Q | **simplified IAM model** (POC model only, not AWS) |
| L8 | Wildcard repository / service / role / bucket names rejected | 4 fixtures in `tests/fixtures/task4/` |

The drift check (L3) was mutation-tested: an added action, a widened resource and
a changed `iam:PassedToService` value each make the comparison fail. An identical
copy passes.

### Local evidence

```
Date: 2026-09-28   Terraform: v1.5.4   hashicorp/aws: v6.66.0   (actual run output)
Offline plan: account-a 22 to add (5 EC2 + 15 IAM Task 3 + 2 CI policy/attachment)

Regressions (same run, case-sensitive failure counter)
POC-1 Regression                                         PASS   (0 real failures)
POC-2 Regression                                         PASS   (0 real failures)
POC-3 Regression                                         PASS   (0 real failures)
TEMP workspaces left behind                              0

POC-4 LOCAL (8 / 8 checks)
Baseline: repo fmt/init/validate/hygiene                 PASS
Terraform policy structure                               PASS
Rendered policy JSON (== policies/ci-policy.json)        PASS
Wildcard-resource exceptions reviewed                    PASS
Broad managed policies absent                            PASS
Excluded actions absent                                  PASS
Least-privilege access matrix A-Q (model, not AWS)       PASS   POC MODEL ONLY
Wildcard CI targets rejected                             PASS

POC-4 (LOCAL): PASS  (8/8 checks; no AWS resources were created)

Access matrix (model):
  A  ecr:GetAuthorizationToken *                          ALLOW
  B  6 push actions on target repository                  ALLOW
  C  PutImage / InitiateLayerUpload on another repo       DENY
  D  BatchDeleteImage / DeleteRepository / SetRepositoryPolicy  DENY
  E  ecs:RegisterTaskDefinition *                         ALLOW
  F  UpdateService / DescribeServices on target service   ALLOW
  G  UpdateService other service / other cluster, CreateService, DeleteService, RunTask  DENY
  H  PassRole execution role -> ecs-tasks                 ALLOW
  I  PassRole task role -> ecs-tasks                      ALLOW
  J  PassRole roleA / an admin role                       DENY
  K  PassRole allowed role -> lambda / ec2 / no context   DENY
  L  s3:ListBucket artifact bucket                        ALLOW
  M  s3:GetObject artifact object                         ALLOW
  N  PutObject / DeleteObject / PutBucketPolicy           DENY
  O  another bucket, roleC's Account B bucket             DENY
  P  ci -> AssumeRole roleB                               DENY (identity=ImplicitDeny, trust=Deny)
  Q  iam:CreateUser/AttachUserPolicy/CreateAccessKey/PutUserPolicy, ec2:Run/Terminate  DENY

REAL AWS POC
Actual ECR push                                          PENDING
Actual ECS task registration                             PENDING
Actual ECS service deployment                            PENDING
Actual iam:PassRole                                      PENDING
Actual S3 artifact read                                  PENDING
Negative AWS authorization tests                         PENDING
```

---

## 2. REAL AWS POC (pending)

### Prerequisites (created outside this repo, e.g. by an administrator via roleA)

| Target | Name (defaults) |
|---|---|
| ECR repository | `aws-terraform-devops-assignment-app` (+ a second repo, `some-other-repo`, for test C) |
| ECS cluster / service | `aws-terraform-devops-assignment-cluster` / `aws-terraform-devops-assignment-service` (+ a second service for test G) |
| Task execution role | `aws-terraform-devops-assignment-ecs-execution` (trust: `ecs-tasks.amazonaws.com`) |
| Task role | `aws-terraform-devops-assignment-ecs-task` (trust: `ecs-tasks.amazonaws.com`) |
| Artifact bucket | `aws-terraform-devops-assignment-artifacts-<account>` with one object, e.g. `builds/app.zip` |

Apply account-a (`terraform apply`), then give the shell **ci** credentials. For
the test only, use a temporary access key deleted afterwards
(`aws iam create-access-key --user-name ci`, then `aws configure --profile ci`).
In production, use a GitHub OIDC role instead (NOTES.md Q5).

```powershell
$env:AWS_PROFILE = 'ci'
$acct = '<ACCOUNT_A_ID>'
$region = 'us-east-1'
$repo = "$acct.dkr.ecr.$region.amazonaws.com/aws-terraform-devops-assignment-app"
```

### Positive tests

| # | Command | Expected |
|---|---|---|
| A | `aws ecr get-login-password --region $region \| docker login --username AWS --password-stdin "$acct.dkr.ecr.$region.amazonaws.com"` | `Login Succeeded` |
| B | `docker pull public.ecr.aws/docker/library/busybox:latest; docker tag public.ecr.aws/docker/library/busybox:latest "${repo}:poc"; docker push "${repo}:poc"` | push succeeds |
| E | `aws ecs register-task-definition --cli-input-json file://taskdef.json` (taskdef references the execution role and task role ARNs and image `${repo}:poc`) | new revision returned. This also exercises **H** and **I** (`iam:PassRole` on both roles). |
| F | `aws ecs update-service --cluster aws-terraform-devops-assignment-cluster --service aws-terraform-devops-assignment-service --task-definition <family>:<rev>`, then `aws ecs wait services-stable --cluster ... --services ...` | deployment starts and becomes stable |
| L | `aws s3 ls s3://aws-terraform-devops-assignment-artifacts-$acct/builds/` | listing |
| M | `aws s3 cp s3://aws-terraform-devops-assignment-artifacts-$acct/builds/app.zip .` | download |

### Negative tests

| # | Command | Expected |
|---|---|---|
| C | `docker tag ... "$acct.dkr.ecr.$region.amazonaws.com/some-other-repo:poc"; docker push ...` | `denied: ... not authorized to perform: ecr:InitiateLayerUpload` |
| D | `aws ecr batch-delete-image --repository-name aws-terraform-devops-assignment-app --image-ids imageTag=poc` / `aws ecr delete-repository --repository-name aws-terraform-devops-assignment-app` | `AccessDeniedException` |
| G | `aws ecs update-service --cluster aws-terraform-devops-assignment-cluster --service <other-service> --task-definition <family>:<rev>` / `aws ecs create-service ...` / `aws ecs delete-service ...` | `AccessDeniedException` |
| J | register a task definition whose `taskRoleArn` is `arn:aws:iam::$acct:role/roleA` | `not authorized to perform: iam:PassRole on resource: ...roleA` |
| K | as an administrator: `aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::${acct}:user/ci --action-names iam:PassRole --resource-arns arn:aws:iam::${acct}:role/aws-terraform-devops-assignment-ecs-execution --context-entries ContextKeyName=iam:PassedToService,ContextKeyValues=lambda.amazonaws.com,ContextKeyType=string` | `"EvalDecision": "implicitDeny"` (and `allowed` with `ecs-tasks.amazonaws.com`) |
| N | `aws s3 cp poc.txt s3://aws-terraform-devops-assignment-artifacts-$acct/builds/poc.txt` / `aws s3 rm s3://aws-terraform-devops-assignment-artifacts-$acct/builds/app.zip` | `AccessDenied` |
| O | `aws s3 ls s3://<any-other-bucket>` | `AccessDenied` |
| P | `aws sts assume-role --role-arn arn:aws:iam::${acct}:role/roleB --role-session-name ci-test` | `AccessDenied` |
| Q | `aws iam create-user --user-name ci-escalation-test` / `aws iam attach-user-policy --user-name ci --policy-arn arn:aws:iam::aws:policy/AdministratorAccess` | `AccessDenied` |

**Tip:** `aws iam simulate-principal-policy` (run by an administrator) evaluates
the real deployed policy for any action/resource/context combination. It's the
AWS counterpart of the local model and is useful for the whole A-Q matrix before
running live commands.

### Cleanup

```powershell
$env:AWS_PROFILE = 'account-a'
aws ecr batch-delete-image --repository-name aws-terraform-devops-assignment-app --image-ids imageTag=poc
aws iam list-access-keys --user-name ci
aws iam delete-access-key --user-name ci --access-key-id <KEY_ID>
```

### Real-AWS evidence

```
Date:
Account (last 4 digits only):
A  ECR auth                :
B  ECR push target         :
C  ECR push other repo     :
D  ECR delete              :
E  Register task def       :
F  Update target service   :
G  Other service / create  :
H/I PassRole exec/task     :
J  PassRole unrelated role :
K  PassRole non-ECS (sim)  :
L/M S3 list/read           :
N  S3 write/delete         :
O  Other bucket            :
P  AssumeRole roleB        :
Q  IAM administration      :
POC-4 (REAL AWS)           :
```
