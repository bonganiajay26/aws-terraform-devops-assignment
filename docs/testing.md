# Testing Strategy

Two phases are kept strictly separate.

## Phase 1 - LOCAL VALIDATION (no AWS account)

| Check | Command | Proves |
|---|---|---|
| Formatting | `terraform fmt -check -recursive` | Canonical style |
| Init | `terraform -chdir=<stack> init -backend=false` | Providers resolve; version constraints satisfiable |
| Validate | `terraform -chdir=<stack> validate` | Syntax, types, references, lifecycle rules valid |
| Hygiene | `scripts/validate-local.ps1` | No state, tfvars, keys or access-key patterns committable |

Local validation does NOT prove that IAM policies behave correctly, that AWS
accepts the values, or that resources deploy.

### Offline plan technique (Task 1+)

`scripts/task1-local-poc.ps1` writes a temporary `account-a/offline_override.tf`
(git-ignored by `*_override.tf`, always deleted in `finally`) that gives the AWS
provider mock credentials plus `skip_credentials_validation`,
`skip_requesting_account_id`, `skip_metadata_api_check` and `skip_region_validation`,
and clears `allowed_account_ids`. `terraform plan -refresh=false` then runs with **zero
AWS API calls**, and the script asserts on `terraform show -json` output.

This proves resource counts, addresses, computed arguments, tags, validation rules
and output shapes. It does not prove AWS acceptance (AMI exists, key pairs exist,
quotas, IAM permissions).

### Mechanism demos

Behaviour that needs existing state (such as `prevent_destroy`) is demonstrated with
Terraform's built-in `terraform_data` resource in a TEMP folder. It is labelled as a
mechanism demo, never as AWS evidence.

## Phase 2 - REAL AWS POC VALIDATION (when accounts exist)

`terraform plan` / `apply`, AWS CLI verification, positive and negative access tests.
Each task's procedure lives in `tests/taskN-test.md`; evidence (redacted command
output) is pasted there with a date. Nothing is marked PASS in Phase 2 without real output.
