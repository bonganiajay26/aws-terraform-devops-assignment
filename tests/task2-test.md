# Task 2 - Remote State and Locking - Test Procedure

- **Phase 1 - LOCAL** (done, no AWS account): `scripts/task2-local-poc.ps1`
- **Phase 2 - REAL AWS** (pending an account): section 2

---

## 1. LOCAL POC (no AWS)

```powershell
Set-Location C:\work\aws-terraform-devops-assignment
powershell -ExecutionPolicy Bypass -File .\scripts\task2-local-poc.ps1
```

| # | Check | Expected |
|---|---|---|
| L1 | Baseline fmt / init / validate / hygiene | PASS |
| L2 | Offline plan of `bootstrap/` | `Plan: 8 to add`; bucket versioned, AES256, 4x public access block, BucketOwnerEnforced, TLS-only policy, lifecycle (90 days, newest 10 kept), `force_destroy = false` |
| L3 | Lock table in the same plan | hash key `LockID` (S), PAY_PER_REQUEST, deletion protection, PITR, SSE |
| L4 | `kms_key_arn` set | `aws:kms` + `bucket_key_enabled = true` |
| L5 | Invalid bucket name / KMS ARN / retention 0 | rejected by validation |
| L6 | Guards | `prevent_destroy = true` on bucket and table |
| L7 | Backend config | keys `account-a/terraform.tfstate` vs `account-b/terraform.tfstate`; `encrypt = true`; no hard-coded bucket; `backend.hcl.example` matches bootstrap names; `backend.hcl` git-ignored |
| L8 | Real s3 backend, no credentials | `init` fails (`no valid credential sources for S3 Backend found`), no local `terraform.tfstate` created |
| L9 | Local demo (local backend, Windows) | Terraform refuses a competing **local-state** writer (`Error acquiring the state lock`); after release a new operation proceeds |

**What L9 does NOT prove:** S3 remote state or DynamoDB locking. It uses the local
backend. On Windows that backend's byte-range file lock also makes the competing
process fail immediately with a read error instead of retrying, so `-lock-timeout`
waiting cannot be shown locally. With DynamoDB, Terraform retries the conditional
write until the timeout, which is test R6 (REAL AWS, pending).

### Local evidence

```
Date: 2026-09-28   Terraform: v1.5.4   hashicorp/aws: v6.66.0   (actual run output)

POC-1 Regression
----------------
Task 1 local POC                                         PASS

POC-2
-----
Baseline: repo fmt/init/validate/hygiene                 PASS
Bootstrap terraform fmt                                  PASS
Bootstrap terraform init                                 PASS
Bootstrap terraform validate                             PASS
S3 security configuration                                PASS
S3 versioning                                            PASS
DynamoDB LockID configuration                            PASS
Invalid bootstrap inputs rejected                        PASS
State infrastructure prevent_destroy                     PASS
Account A backend configuration                          PASS
Account B backend configuration                          PASS
No silent fallback to local state                        PASS
Local competing writer rejected                          PASS

POC-2 (LOCAL): PASS  (no AWS resources were created)

LOCAL POC
Terraform refused a competing local-state writer.        PASS

REAL AWS POC
S3 remote state actually created.                        PENDING
DynamoDB state locking actually exercised.               PENDING
Two concurrent Terraform operations tested against AWS.  PENDING

Key observed messages:
  Plan: 8 to add, 0 to change, 0 to destroy.
  Error: error configuring S3 Backend: no valid credential sources for S3 Backend found.
  Error: Error acquiring the state lock
  read terraform.tfstate: The process cannot access the file because another
  process has locked a portion of the file.
```

---

## 2. REAL AWS POC (pending)

### Prerequisites - CLI profiles

```powershell
aws configure sso --profile account-a
aws configure sso --profile account-b
aws sts get-caller-identity --profile account-a
aws sts get-caller-identity --profile account-b
```

(Use `aws configure --profile ...` with temporary credentials if Identity Center is
not available. Never paste keys into repository files.)

### R1 - Bootstrap (local state, run once)

```powershell
Set-Location C:\work\aws-terraform-devops-assignment\bootstrap
Copy-Item terraform.tfvars.example terraform.tfvars
$env:AWS_PROFILE = 'account-a'
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output
$b = terraform output -raw state_bucket_name
$t = terraform output -raw lock_table_name
```

Set `state_account_id` in `terraform.tfvars` to the real Account A ID first.
Expected: `Apply complete! Resources: 8 added`.

### R2 - Verify state infrastructure

```powershell
aws s3api get-bucket-versioning --bucket $b
aws s3api get-bucket-encryption --bucket $b
aws s3api get-public-access-block --bucket $b
aws s3api get-bucket-ownership-controls --bucket $b
aws s3api get-bucket-policy --bucket $b --query Policy --output text
aws dynamodb describe-table --table-name $t --query "Table.{Name:TableName,Key:KeySchema,Billing:BillingModeSummary.BillingMode,DeletionProtection:DeletionProtectionEnabled,SSE:SSEDescription.Status}"
aws dynamodb describe-continuous-backups --table-name $t --query "ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus"
```

| Check | Expected |
|---|---|
| Versioning | `"Status": "Enabled"` |
| Encryption | `"SSEAlgorithm": "AES256"` |
| Public access block | all four `true` |
| Ownership | `BucketOwnerEnforced` |
| Policy | `DenyInsecureTransport` with `aws:SecureTransport = false` |
| Table | key `LockID` HASH, `PAY_PER_REQUEST`, deletion protection `true`, SSE `ENABLED` |
| PITR | `ENABLED` |

### R3 - Negative security checks

```powershell
aws s3api list-objects-v2 --bucket $b --endpoint-url http://s3.us-east-1.amazonaws.com
aws s3api put-bucket-acl --bucket $b --acl public-read
aws dynamodb delete-table --table-name $t
```

Expected: `AccessDenied` (plain HTTP refused by the policy),
`AccessControlListNotSupported` (ACLs disabled), and a deletion-protection error.

### R4 - account-a backend (and migration from local state)

```powershell
Set-Location ..\account-a
Copy-Item backend.hcl.example backend.hcl
terraform init -backend-config=backend.hcl
```

- **No local state yet:** `Successfully configured the backend "s3"!`
- **Task 1 was applied earlier with local state:** Terraform asks
  `Do you want to copy existing state to the new backend?`. Use the explicit form instead:
  ```powershell
  Copy-Item terraform.tfstate terraform.tfstate.pre-migration.bak
  terraform init -backend-config=backend.hcl -migrate-state
  terraform state list
  aws s3 ls "s3://$b/account-a/"
  ```
  Expected: the same resource list as before, and `terraform.tfstate` visible in S3.
  Then delete the local `terraform.tfstate*` files (they are git-ignored, but stale).

### R5 - account-b backend

```powershell
Set-Location ..\account-b
Copy-Item backend.hcl.example backend.hcl
$env:AWS_PROFILE = 'account-b'
terraform init -backend-config=backend.hcl
```

The backend uses `profile = "account-a"` (the state bucket is in Account A) while
the provider uses `AWS_PROFILE=account-b`.

### R6 - Two competing operations (the locking POC)

Terminal 1:

```powershell
Set-Location C:\work\aws-terraform-devops-assignment\account-a
$env:AWS_PROFILE = 'account-a'
terraform apply
```

Leave it at the `Enter a value:` prompt. An apply waiting for approval **holds the lock**.

Terminal 2:

```powershell
Set-Location C:\work\aws-terraform-devops-assignment\account-a
$env:AWS_PROFILE = 'account-a'
aws dynamodb scan --table-name aws-terraform-devops-assignment-tf-locks --query "Items[].LockID.S"
terraform plan -lock-timeout=0s
```

Expected in terminal 2:

```
"aws-terraform-devops-assignment-tfstate-<acct>/account-a/terraform.tfstate"
...
Error: Error acquiring the state lock
Error message: ConditionalCheckFailedException: The conditional request failed
Lock Info:
  ID:        <uuid>
  Path:      aws-terraform-devops-assignment-tfstate-<acct>/account-a/terraform.tfstate
  Operation: OperationTypeApply
  Who:       <user>@<host>
  Version:   1.5.4
  Created:   <timestamp>
```

Then, in terminal 2:

```powershell
terraform plan -lock-timeout=120s
```

Expected: `Acquiring state lock. This may take a few moments...` and it **waits**.
Answer `no` in terminal 1. Terminal 2 then gets the lock and completes the plan.

### R7 - Separate keys do not block each other

While terminal 1 holds the account-a lock, run `terraform plan` in `account-b`.
Expected: it proceeds, because its LockID is `.../account-b/terraform.tfstate`.

### R8 - Versioning recovery

```powershell
aws s3api list-object-versions --bucket $b --prefix account-a/terraform.tfstate --query "Versions[].{Id:VersionId,Latest:IsLatest,Modified:LastModified}"
```

Expected: one version per state write. Any earlier version can be restored.

### Stale lock (crashed process)

```powershell
terraform force-unlock <LOCK_ID>
```

Only use this when you are sure the lock holder is no longer running.

### Real-AWS evidence

```
Date:
Account (last 4 digits only):
R1 bootstrap apply   :
R2 settings verified :
R3 negative checks   :
R4 account-a backend :
R5 account-b backend :
R6 lock error + wait :
R7 separate keys     :
R8 versions listed   :
POC-2 (REAL AWS)     :
```

---

## 3. Cleanup (real AWS) - deliberate, multi-step by design

1. Destroy/migrate every stack that uses the backend first (account-a, account-b).
2. In `bootstrap/main.tf` temporarily set `prevent_destroy = false` (bucket + table)
   and `deletion_protection_enabled = false`; `terraform apply`.
3. Empty the bucket, **including all object versions and delete markers** (console
   "Empty bucket", or delete each version).
4. `terraform destroy` in `bootstrap/`.
5. Revert the temporary changes.
