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

### IAM policy model (Tasks 3-4)

`scripts/IamPolicyModel.psm1` evaluates the **Terraform-rendered** policy JSON
from the offline plans. It models identity policies (explicit Deny > Allow >
implicit deny), trust policies (exact ARN / account root / `*`), `Action` /
`NotAction` wildcards, `${aws:username}`, and the `Bool` / `StringEquals`
conditions used here (`aws:MultiFactorAuthPresent`, `iam:PassedToService`).

It is a **POC model only**. It does not model SCPs, permission boundaries,
session policies, resource policies other than trust, or other condition
operators, and it compares condition values case-insensitively, whereas AWS
`StringEquals` is case-sensitive. Its results are labelled "model, not AWS". The AWS counterpart is
`aws iam simulate-principal-policy` plus the live tests in `tests/task3-test.md`
and `tests/task4-test.md`.

### Reference-policy drift check (Task 4)

`policies/ci-policy.json` must stay semantically identical to the policy rendered
from `account-a/ci-policy.tf`. POC-4 compares both in an order-independent form
(statements, actions, resources and conditions). The comparison was
mutation-tested: an added action, a widened resource or a changed condition each
make it fail.

### Bug fixtures (Task 5)

`tests/fixtures/task5/` holds the original **broken** roleC policies
(`user/roleB` trust, `s3:*` on `*`) as test data only, plus **fixed** copies.
POC-5 evaluates both with the IAM model, asserts that no deployable `.tf`
references the fixtures or contains either broken pattern, and asserts that the
fixed copies match the Terraform-rendered roleC policies (Terraform is the source
of truth).

### Full local regression

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-regression.ps1
```

`scripts/run-regression.ps1` runs the repository gates (fmt, validate x3,
validate-local, `git diff --check`) and POC-1..POC-5 sequentially, never
concurrently. For each POC it:

1. saves the raw output to `tests/evidence/local/pocN-latest.log` (git-ignored)
   **before** interpreting it;
2. applies a case-sensitive failure matcher
   (`[FAIL]`, a line ending in ` FAIL`, `Could not fully remove`, `ERROR:`) and prints
   every matched line with its log line number. Expected `Error:` lines from
   negative tests are counted separately and are not failures;
3. snapshots POC workspace folders (`%TEMP%\task<N>-poc-*`) before and after and
   fails if the POC left any of its own workspaces behind. Unrelated `%TEMP%`
   content is ignored.

TEMP cleanup is strict: `Remove-TempWorkspace` retries with bounded backoff
(about 50 s at most) because Windows can keep a file lock on the copied provider
binary (876,995,208 bytes, ~836 MiB). The locking process has not been identified. A workspace that survives
the retry budget is reported as `[FAIL]`, and the POC exits non-zero.

## Phase 2 - REAL AWS POC VALIDATION (when accounts exist)

`terraform plan` / `apply`, AWS CLI verification, positive and negative access tests.
Each task's procedure lives in `tests/taskN-test.md`; evidence (redacted command
output) is pasted there with a date. Nothing is marked PASS in Phase 2 without real output.
