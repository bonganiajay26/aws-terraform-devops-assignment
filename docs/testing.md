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

`scripts/OfflineWorkspace.psm1` (used by the Task 1 and Task 2 POC scripts) copies
one root module plus `modules/` into a **TEMP folder**. It drops `backend.tf` there
and adds an `offline_override.tf` that gives the AWS provider mock credentials plus
`skip_credentials_validation`, `skip_requesting_account_id`, `skip_metadata_api_check`
and `skip_region_validation`, and clears `allowed_account_ids`. It initialises with
`-plugin-dir` pointing at the providers already downloaded in the repo.
`terraform plan -refresh=false` then runs with **zero AWS API calls**, and the scripts
assert on `terraform show -json` output. Nothing (override, `.terraform` metadata or
state) is written inside the repository, and the TEMP folder is deleted afterwards.

This proves resource counts, addresses, computed arguments, tags, validation rules
and output shapes. It does not prove AWS acceptance (AMI exists, key pairs exist,
quotas, IAM permissions).

### Mechanism demos

Behaviour that needs existing state (such as `prevent_destroy`) is demonstrated with
Terraform's built-in `terraform_data` resource in a TEMP folder. It is labelled as a
mechanism demo, never as AWS evidence.

The Task 2 lock demo (local backend) proves only that **Terraform refused a competing
local-state writer**. It does NOT prove S3 remote state or DynamoDB locking. Those
are REAL AWS POC items, still pending.

## Phase 2 - REAL AWS POC VALIDATION (when accounts exist)

`terraform plan` / `apply`, AWS CLI verification, positive and negative access tests.
Each task's procedure lives in `tests/taskN-test.md`; evidence (redacted command
output) is pasted there with a date. Nothing is marked PASS in Phase 2 without real output.
