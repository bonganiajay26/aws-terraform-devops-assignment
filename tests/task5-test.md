# Task 5 - Find and Fix the IAM Bugs - Test Procedure

- **Phase 1 - LOCAL** (done): `scripts/task5-local-poc.ps1`
- **Phase 2 - REAL AWS** (pending): section 2

The corrected policies are the Task 3 Terraform (`account-b/role-c.tf`), which is
the **source of truth**. The broken versions exist only as fixtures in
`tests/fixtures/task5/` and are never referenced by deployable Terraform.

```
BUG 1 - WRONG PRINCIPAL TYPE
  BROKEN  arn:aws:iam::000000000000:user/roleB
  FIXED   arn:aws:iam::000000000000:role/roleB

BUG 2 - S3 OVER-PERMISSION
  BROKEN  Action s3:*  Resource "*"
  FIXED   Action s3:*  Resource arn:aws:s3:::<bucket>  and  arn:aws:s3:::<bucket>/*
```

---

## 1. LOCAL POC (no AWS)

```powershell
Set-Location C:\work\aws-terraform-devops-assignment
powershell -ExecutionPolicy Bypass -File .\scripts\task5-local-poc.ps1
```

The identity side of the AssumeRole test is the **real rendered roleB policy**
from the account-a offline plan. The "deployed" policies are the rendered roleC
trust and permissions from the account-b offline plan. Access decisions come from
the simplified IAM model (**POC model only, not AWS**).

### Local evidence

```
Date: 2026-09-28   Terraform: v1.5.4   hashicorp/aws: v6.66.0   (actual run output)

POC-5 LOCAL (15 / 15 checks)
Baseline: repo fmt/init/validate/hygiene                 PASS

BROKEN POLICY PROOF
user/roleB principal detected                            PASS
roleB cannot satisfy broken trust                        PASS   (identity=Allow, trust=Deny)
s3:* / Resource "*" detected                             PASS
unrelated S3 resource becomes accessible                 PASS   (ListBucket/GetObject/DeleteBucket/PutBucketPolicy/ListAllMyBuckets)

FIXED POLICY PROOF
fixed role/roleB trust permits roleB                     PASS   (fixed fixture AND deployed trust)
exact role/roleB trust                                   PASS
target bucket allowed                                    PASS
target objects allowed                                   PASS   (Get/Put/DeleteObject)
unrelated bucket denied                                  PASS
unrelated objects denied                                 PASS

DRIFT / DEPLOYMENT SAFETY
fixed trust + S3 fixtures == rendered policies           PASS   (no drift)
deployable code has no broken principal                  PASS   (26 .tf files, code lines + rendered trust)
deployed S3 policy has no Resource "*"                   PASS
fixtures not referenced by Terraform                     PASS

POC-5 (LOCAL): PASS  (15/15 checks; no AWS resources were created)
IAM evaluator: POC MODEL ONLY

Illustration (info): the broken trust would instead admit an IAM USER literally
named roleB, if one existed.

REAL AWS POC
Broken trust before-test                                 PENDING
Fixed roleB -> roleC AssumeRole                          PENDING
Broken broad-S3 before-test                              PENDING
Fixed target-bucket access                               PENDING
Fixed other-bucket denial                                PENDING
```

### Regression incident (2026-09-29) - harness cleanup, not a Task 5 / IAM failure

The first full regression after Task 5 reported `POC-3 exit=0 realFails=1` and
`new TEMP dirs left: 1`, although POC-3 itself passed 23/23.

- Leftover workspace: `%TEMP%\task3-poc-4d9a631c` (created 2026-09-29 00:03:40),
  containing one file:
  `account-a\account-a\.terraform\providers\registry.terraform.io\hashicorp\aws\6.66.0\windows_amd64\terraform-provider-aws_v6.66.0_x5.exe`,
  876,995,208 bytes, last written 2026-09-29 00:04:51. No terraform process
  was still running afterwards.
- The regression driver at that time only *counted* matched lines, so the
  exact matched line was not captured. The only matcher pattern consistent with
  a PASS summary and a leftover workspace is the cleanup helper's
  "Could not fully remove" warning.
- An isolated POC-3 rerun passed with 0 matched lines and 0 leftovers.
- Supported statement: Windows retained a file lock on the copied AWS provider
  binary longer than the cleanup retry window (10 x 1 s). Antivirus, indexing or
  scanning is one possible cause, but the locking process was not identified.
- The leftover's metadata was recorded (above), and the folder was then deleted
  (`Test-Path` = `False`).

Fixes (test harness only, no Terraform changes):
1. `Remove-TempWorkspace` uses bounded backoff (immediate attempt, then 1,1,2,2,4,5,5,10,10,10 s),
   reports the attempt count when a lock was released late, and returns failure,
   with the path preserved, if the workspace still exists. Every POC script now
   treats a failed cleanup as `TEMP workspace cleanup FAIL` and exits non-zero.
   Self-tested with real exclusive file locks: immediate = PASS, released
   after ~3 s = PASS (4 attempts), never released = FAIL (11 attempts, ~50 s).
2. `scripts/run-regression.ps1` writes each POC's raw output to
   `tests/evidence/local/pocN-latest.log` (git-ignored) **before** interpreting
   it, prints every matched failure line with its log line number, and gates
   TEMP on workspaces created by each POC (before/after snapshot), not on all of `%TEMP%`.

`account-b/role-c.tf` mentions `:user/roleB` in a **comment** that documents the
bug. The "no user/roleB" check therefore scans code lines, and separately checks
the rendered trust policy, which is what AWS actually receives.

---

## 2. REAL AWS POC (pending)

Run in a **disposable test setup**, never against the real roleC. Use a
separate, temporary role name (`roleC-bugtest`) so the correct roleC is never
modified.

### BUG 1 - before (broken trust)

```powershell
$env:AWS_PROFILE = 'account-b'
aws iam create-role --role-name roleC-bugtest --assume-role-policy-document file://tests/fixtures/task5/broken-trust-policy.json
```

Replace `000000000000` in the fixture with the real Account A ID first (in a
temporary copy, not in the repo).

The defect under test is that the principal ARN identifies the **user**
`user/roleB`, not the **role** roleB. Expected outcome: the intended caller,
roleB, cannot assume `roleC-bugtest`. Record which of these AWS returns (it can
vary with principal existence and resolution):

- the policy is rejected when saved (`MalformedPolicyDocument` / invalid principal), or
- the role is created, but
  `aws sts assume-role --role-arn arn:aws:iam::<B>:role/roleC-bugtest ...` from
  **roleB** credentials fails with `AccessDenied ... not authorized to perform:
  sts:AssumeRole`.

### BUG 1 - after (fixed trust)

```powershell
aws iam update-assume-role-policy --role-name roleC-bugtest --policy-document file://tests/fixtures/task5/fixed-trust-policy.json
```

Then, from roleB credentials (see `tests/task3-test.md` TEST A):

```powershell
aws sts assume-role --role-arn arn:aws:iam::<B>:role/roleC-bugtest --role-session-name bugfix-test
```

Expected: **SUCCESS**. (The deployed roleC is verified by `tests/task3-test.md` TEST B.)

### BUG 2 - before (s3:* on *)

```powershell
aws iam put-role-policy --role-name roleC-bugtest --policy-name broken-s3 --policy-document file://tests/fixtures/task5/broken-s3-policy.json
```

With roleC-bugtest credentials:

```powershell
aws s3 ls
aws s3 ls s3://aws-terraform-devops-assignment-control-<B>
```

Expected: **both succeed**. The role sees every bucket and the unrelated control
bucket, which demonstrates the over-permission.

### BUG 2 - after (bucket-scoped)

```powershell
aws iam put-role-policy --role-name roleC-bugtest --policy-name broken-s3 --policy-document file://tests/fixtures/task5/fixed-s3-policy.json
```

Wait about 10-30 seconds for IAM propagation, then with fresh roleC-bugtest credentials:

```powershell
aws s3 ls s3://aws-terraform-devops-assignment-crossacct-<B>/
aws s3 ls s3://aws-terraform-devops-assignment-control-<B>
aws s3 ls
```

Expected: the target bucket **succeeds**; the control bucket and `ListAllMyBuckets` give **AccessDenied**.

### Cleanup

```powershell
aws iam delete-role-policy --role-name roleC-bugtest --policy-name broken-s3
aws iam delete-role --role-name roleC-bugtest
```

### Real-AWS evidence

```
Date:
Accounts (last 4 digits only):
BUG 1 before (broken trust)     :
BUG 1 after  (roleB -> roleC)   :
BUG 2 before (other bucket OK)  :
BUG 2 after  (target OK)        :
BUG 2 after  (other denied)     :
POC-5 (REAL AWS)                :
```
