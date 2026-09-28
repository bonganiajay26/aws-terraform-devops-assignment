# Troubleshooting

## Task 0

| Symptom | Cause | Fix |
|---|---|---|
| `terraform : The term 'terraform' is not recognized` | Not installed or PATH not refreshed | `winget install --id HashiCorp.Terraform -e`, then open a NEW PowerShell window |
| `... cannot be loaded because running scripts is disabled` | Execution policy | `Set-ExecutionPolicy -Scope Process Bypass` (current window only) |
| `terraform fmt -check` lists files you did not change | CRLF line endings from a Windows editor | Run `terraform fmt -recursive`; set VS Code to LF; `.gitattributes` normalises on commit |
| `Failed to query available provider packages` | No internet / corporate proxy | Set `$env:HTTPS_PROXY` or use a network that reaches registry.terraform.io |
| `The filename or extension is too long` during init | Windows 260-character path limit | Keep the repo at a short path such as `C:\work\aws-terraform-devops-assignment` |
| `Unsupported Terraform Core version` or `too old` | Local Terraform < 1.5 | Chocolatey install: `choco upgrade terraform -y` (Administrator). winget install: `winget upgrade --id HashiCorp.Terraform`. Check with `Get-Command terraform -All` that only one terraform.exe is on PATH |
| `Author identity unknown` on commit | Git user not configured | `git config --global user.name "Your Name"` and `git config --global user.email "you@example.com"` |
| CI `secret-hygiene` fails | Forbidden file committed | `git rm --cached <file>`, commit, and ROTATE any exposed credential |

## Task 1

| Symptom | Cause | Fix |
|---|---|---|
| `Error: Variables not allowed` on `prevent_destroy` | Lifecycle values must be literals | Use the two-block split in `modules/ec2/main.tf`; never `each.value.*` in `lifecycle` |
| `Error: Instance cannot be destroyed` | Plan destroys/replaces `aws_instance.protected[...]` | Intended. Check why: removed from map, or a replacement-forcing change (AMI, key_name, subnet). To remove deliberately see `tests/task1-test.md` section 3 |
| `Error: Module not installed` | `ec2.tf` added after the last init | `terraform -chdir=account-a init -backend=false` |
| `No value for required variable "ami_id"` / `"instances"` | No tfvars passed | `Copy-Item terraform.tfvars.example terraform.tfvars` and edit, or `-var-file=terraform.tfvars.example` for a local plan |
| `Error: Too many command line arguments` in PowerShell | PS 5.1 splits unquoted args like `-var-file=x.tfvars` at the dot | Quote them: `'-var-file=terraform.tfvars.example'` |
| `InvalidAMIID.NotFound` (real AWS) | AMI from another region / placeholder AMI | Look up the AMI in the provider region (README Task 1) |
| `InvalidKeyPair.NotFound` (real AWS) | Key pair missing in the region | Create web01..05-key (`tests/task1-test.md`) |
| `InvalidParameterCombination ... iops` (real AWS) | IOPS on gp2 or ratio exceeded | Validation normally catches this at plan; check the limits table in README |
| `VcpuLimitExceeded` / `InsufficientInstanceCapacity` (real AWS) | New-account vCPU quota (t3.xlarge = 4 vCPU) | Request a quota increase or use smaller types for the POC |
| `No default VPC for this user` (real AWS) | Default VPC deleted | Set `subnet_id` and `vpc_security_group_ids` in `terraform.tfvars` |
| `OperationNotPermitted` terminating web03 in console | `disable_api_termination = true` | Intended. Follow the cleanup procedure |

## Task 2

| Symptom | Cause | Fix |
|---|---|---|
| `Error: Backend initialization required, please run "terraform init"` | Stack has `backend "s3"` but was initialised with `-backend=false` (or not at all) | Local checks: use the scripts (they plan in a TEMP copy). Real AWS: `terraform init -backend-config=backend.hcl` |
| `error configuring S3 Backend: no valid credential sources for S3 Backend found` | No AWS credentials for the backend | `aws configure sso --profile account-a` / `aws sso login --profile account-a`; `backend.hcl` must name that profile |
| `failed to get shared config profile, account-a` | Profile in `backend.hcl` does not exist | Create the profile or change `profile` in `backend.hcl` |
| `NoSuchBucket` / `ResourceNotFoundException` on init | Bootstrap not applied, or wrong names/region in `backend.hcl` | Apply `bootstrap/`; copy values from `terraform -chdir=bootstrap output backend_hcl` |
| `BucketAlreadyExists` on bootstrap apply | S3 bucket names are global | Set a unique `state_bucket_name` in `bootstrap/terraform.tfvars` and the same value in both `backend.hcl` files |
| `Backend configuration changed` on init | `backend.hcl` or `backend.tf` changed since last init | Move state: `-migrate-state`. State already in place: `-reconfigure` (copies nothing) |
| `Do you want to copy existing state to the new backend?` | Local `terraform.tfstate` exists (e.g. Task 1 applied before Task 2) | Back it up, answer `yes` (or use `-migrate-state`), verify with `terraform state list`, then delete local copies |
| Plan wants to CREATE everything after init | `-reconfigure` used when state should have been migrated, or wrong `key` | Stop. Do not apply. Fix `key`/bucket and re-init; restore a previous S3 object version if needed |
| `Error acquiring the state lock` + `ConditionalCheckFailedException` | Another operation holds the DynamoDB lock (Lock Info shows Who/Created) | Wait, or retry with `-lock-timeout=120s`. Never `-lock=false` against shared state |
| Lock remains after a crashed run | Process died before deleting the LockID item | Confirm nobody is running, then `terraform force-unlock <ID>` |
| `state data in S3 does not have the expected content` (checksum) | Digest item in the lock table does not match the state object (manual edit / partial write) | Restore the matching S3 object version, or correct the `-md5` digest item as the error message describes |
| `AccessDenied` using `http://` endpoint | TLS-only bucket policy | Intended. Use HTTPS (the default) |
| `AccessControlListNotSupported` | ACLs disabled (BucketOwnerEnforced) | Intended. Use IAM / bucket policy |
| `Instance cannot be destroyed` in bootstrap | `prevent_destroy` on bucket/table | Intended. Follow `tests/task2-test.md` section 3 |
| Local lock demo: second process fails at once instead of waiting | Windows local backend uses a byte-range file lock and fails fast | Expected. `-lock-timeout` waiting is verified against DynamoDB in the real-AWS POC |

## Task 3

| Symptom | Cause | Fix |
|---|---|---|
| `MalformedPolicyDocument: Invalid principal in policy` creating roleC | roleB does not exist yet (or wrong `account_a_id`) | Apply account-a first; check `account_a_id` in account-b tfvars |
| Same error creating roleA/roleB | Trusted users not created yet | Handled by `depends_on = [aws_iam_user.this]`; re-run apply |
| `AccessDenied ... not authorized to perform: sts:AssumeRole on resource: ...roleC` from roleB | Side 1 (roleB identity policy) or side 2 (roleC trust) wrong | Compare `terraform output role_b_arn` (account-a) with `role_c_trusted_principal` (account-b); check `account_b_id` in account-a |
| roleC trust shows `AROA...` instead of the roleB ARN | roleB was deleted/recreated; trust resolved to the old unique ID | Re-apply account-b so roleC trusts the new roleB |
| `aws s3 ls s3://BUCKET` denied but GetObject works | Only `BUCKET/*` granted | roleC needs both bucket and `bucket/*` ARNs (as implemented) |
| `aws s3 ls` (no bucket) denied for roleC | `s3:ListAllMyBuckets` not granted | Intended: roleC is scoped to one bucket |
| developer1 cannot assume roleA | No MFA in the session | `aws sts assume-role ... --serial-number <mfa-arn> --token-code <code>` or sign in with MFA |
| engine/ci cannot sign in to the console | No login profile (programmatic only) | Intended |
| developer1/2 have no console password after apply | `console_pgp_key` not set, so Terraform creates no login profile (keeps passwords out of state) | Intended. `aws iam create-login-profile --password-reset-required`, or set `console_pgp_key` and re-apply |
| `error encrypting password` / keybase lookup fails on apply | Invalid `console_pgp_key` | Use a valid base64 public key or an existing `keybase:<user>` |
| `EntityAlreadyExists: User with name ... already exists` | Users/roles created manually before | `terraform import 'aws_iam_user.this["engine"]' engine` (or delete the manual one) |
| `BucketAlreadyExists` for the target bucket | Global S3 namespace | Set `target_bucket_name` in account-b tfvars |
| `DeleteConflict` destroying users | Keys/MFA added out of band | `force_destroy = true` handles it; otherwise delete keys first |
| Task 3 POC shows `System.Object[]` or wrong counts | PowerShell 1-element-array unrolling | Use the committed script (the helper keeps arrays intact) |

## Task 4

| Symptom | Cause | Fix |
|---|---|---|
| `denied: ... not authorized to perform: ecr:InitiateLayerUpload` on push | Pushing to a repository other than `ci_ecr_repository_name`, or wrong region/account in the ARN | Tag the image for the configured repository; check `terraform output ci_policy_targets` |
| `no basic auth credentials` on push | `docker login` not done or token expired (12 h) | `aws ecr get-login-password \| docker login ...` |
| `not authorized to perform: iam:PassRole` on register-task-definition | Task definition references a role other than the two configured roles | Use exactly `ci_ecs_task_execution_role_name` / `ci_ecs_task_role_name`, or change the variables deliberately |
| `AccessDeniedException` on `ecs:DescribeTaskDefinition` | Pipeline downloads the live task definition; deliberately not granted | Keep the task definition in the repo, or add a documented `*` exception (NOTES.md Q8) |
| `AccessDeniedException` on update-service | Different service/cluster than configured | Check `ci_ecs_cluster_name` / `ci_ecs_service_name` |
| `aws ecs wait services-stable` fails with AccessDenied | Service ARN mismatch (`DescribeServices` is scoped) | Same as above |
| `AccessDenied` on `s3 cp` upload / `s3 rm` | Read-only by design | Intended |
| POC-4 "rendered policy == policies/ci-policy.json" FAIL | Policy changed in `ci-policy.tf` but not in the reference JSON (or vice versa) | Update both; the check is intentional drift protection |
| POC comparisons print `System.Object[]` / odd booleans | PowerShell: binary `-join` binds looser than `-eq`; nested arrays | The committed script uses `Join-Sorted`; don't inline `-join` inside comparisons |
