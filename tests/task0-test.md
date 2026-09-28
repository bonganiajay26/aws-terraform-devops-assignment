# Task 0 - POC-0 Test Procedure (LOCAL ONLY)

## Positive tests

| # | Test | Command | Expected |
|---|---|---|---|
| P1 | Formatting | `terraform fmt -check -recursive` | No output, exit code 0 |
| P2 | Init all stacks | `terraform -chdir=<stack> init -backend=false` | `Terraform has been successfully initialized!` |
| P3 | Validate all stacks | `terraform -chdir=<stack> validate` | `Success! The configuration is valid.` |
| P4 | Full local suite | `powershell -ExecutionPolicy Bypass -File .\scripts\validate-local.ps1` | Seven PASS lines and `POC-0: PASS` |

## Negative / security tests

| # | Test | Expected |
|---|---|---|
| N1 | Create `account-a/terraform.tfvars`, `account-a/fake.tfstate`, `test.pem`, `.env`; run `git status --porcelain` | None of them listed |
| N2 | `git check-ignore -v <file>` for each | Prints the matching `.gitignore` rule |
| N3 | `git add -f account-a/terraform.tfvars`, then run the validator | `Secret/state check FAIL`, `POC-0: FAIL` |
| N4 | Break indentation in a `.tf` file, run `terraform fmt -check -recursive` | Lists the file, exit code 3 |

## Evidence

Paste redacted output here with a date.

```
Date:
Repository structure
Required files
terraform fmt
terraform init
terraform validate
Secret/state check
Git repository

POC-0:
Commit:
```
