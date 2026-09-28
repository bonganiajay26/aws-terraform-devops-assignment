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

## Phase 2 - REAL AWS POC VALIDATION (when accounts exist)

`terraform plan` / `apply`, AWS CLI verification, positive and negative access tests.
Each task's procedure lives in `tests/taskN-test.md`; evidence (redacted command
output) is pasted there with a date. Nothing is marked PASS in Phase 2 without real output.
