# Task 3 - Multi-account IAM - Test Procedure

- **Phase 1 - LOCAL** (done, no AWS accounts): `scripts/task3-local-poc.ps1`
- **Phase 2 - REAL AWS** (pending two accounts): section 2

---

## 1. LOCAL POC (no AWS)

```powershell
Set-Location C:\work\aws-terraform-devops-assignment
powershell -ExecutionPolicy Bypass -File .\scripts\task3-local-poc.ps1
```

| # | Check | Evidence source |
|---|---|---|
| L1 | Baseline fmt / init / validate / hygiene | `validate-local.ps1` |
| L2 | Offline plans of account-a and account-b | TEMP copies, mock credentials, zero AWS calls |
| L3 | group1 = engine, ci (never a login profile); group2 = developer1, developer2 with self-service scoped to `${aws:username}`. Default plan: **no login profile at all**, so no password in state. With `console_pgp_key`: profiles for group2 only, PGP-encrypted, reset required. **No `aws_iam_access_key`**, no secret outputs. Credential provisioning is intentionally excluded. | plan JSON (2 plans) |
| L4 | roleA: `Allow NotAction iam:*` + explicit `Deny iam:*`; no AdministratorAccess / PowerUserAccess / *FullAccess; trusted only by the two console users, MFA required | rendered policy JSON |
| L5 | roleB: one statement, one action `sts:AssumeRole`, resource = exact roleC ARN; no managed policies | rendered policy JSON |
| L6 | roleC trust: exactly `arn:aws:iam::000000000000:role/roleB`; not `:root`, not `:user/`, no `*`; permissions `s3:*` on bucket ARN + `bucket/*` only | rendered policy JSON |
| L7 | account-a and account-b ARNs agree (roleB, roleC, bucket) | both plans |
| L8 | Local IAM evaluator: access matrix A-E and extras | **simplified IAM model** on the rendered policies (POC model only) |
| L9 | Counterfactual: roleC trusting Account A `:root` would let roleA and the root user in | IAM model |
| L10 | Invalid console users / account ID rejected | 3 fixtures in `tests/fixtures/task3/` |

**About L8/L9:** `scripts/IamPolicyModel.psm1` evaluates identity and trust
policies: explicit deny, wildcards, `NotAction`, `${aws:username}`, and the
`aws:MultiFactorAuthPresent` condition. It is a teaching and verification model,
**not AWS**. It does not model SCPs, permission boundaries, session policies or
other condition keys. Only the real-AWS tests below prove actual behavior.

### Local evidence

```
Date: 2026-09-28   Terraform: v1.5.4   hashicorp/aws: v6.66.0   (actual run output)
Offline plans: account-a 20 to add (5 EC2 + 15 IAM, default mode), account-b 10 to add

POC-1 Regression                                         PASS
POC-2 Regression                                         PASS

POC-3 LOCAL (23 / 23 checks)
Baseline: repo fmt/init/validate/hygiene                 PASS
Account A IAM structure                                  PASS
Account B IAM structure                                  PASS
group1 contains engine + ci                              PASS
group2 contains developer1 + developer2                  PASS
group1 login profiles absent                             PASS
Terraform-managed access keys absent                     PASS
group2 default login profiles absent                     PASS
group2 PGP-mode profile configuration                    PASS   LOCAL STRUCTURAL VALIDATION ONLY
password_reset_required = true                           PASS
plaintext password outputs absent                        PASS
group2 self-service scoped to own user                   PASS
roleA admin except IAM                                   PASS
roleB only AssumeRole exact roleC                        PASS
roleC trusts exact roleB                                 PASS
Account-A root trust absent                              PASS
user/roleB trust absent                                  PASS
roleC S3 target-bucket scope                             PASS
Resource "*" absent from roleC S3 policy                 PASS
Cross-account ARNs consistent                            PASS
Local IAM evaluator: tests A-E (model, not AWS)          PASS   POC MODEL ONLY
Local IAM evaluator: root trust broader (model)          PASS   POC MODEL ONLY
Invalid IAM inputs rejected                              PASS

POC-3 (LOCAL): PASS  (no AWS resources were created)

Placeholder PGP key ("keybase:placeholder-user") proves only the Terraform
configuration path; it is not a usable key and is NOT evidence that AWS created
an encrypted login profile.

Access matrix (model):
  A  engine -> AssumeRole roleB            ALLOWED (identity=Allow, trust=Allow)
  A- ci -> AssumeRole roleB                DENIED  (identity=ImplicitDeny, trust=Deny)
  B  roleB -> AssumeRole roleC             ALLOWED (identity=Allow, trust=Allow)
  C  roleC ListBucket/Get/Put/Delete target ALLOWED
  D  roleC ListBucket/GetObject control     DENIED (ImplicitDeny); ListAllMyBuckets DENIED
  E  roleA -> roleC                        DENIED  (identity=Allow, trust=Deny)
  E  engine / ci / developer1 -> roleC     DENIED
  E  Account A root -> roleC               DENIED  (trust=Deny)
  roleB: ec2/s3/iam/ecr/ecs actions        DENIED
  roleA: ec2/s3/dynamodb ALLOWED; iam:CreateUser/AttachRolePolicy/PassRole ExplicitDeny
  developer1 -> roleA with MFA ALLOWED, without MFA DENIED
  Counterfactual root trust: roleA -> roleC ALLOWED, root -> roleC ALLOWED

REAL AWS POC
TEST A engine -> roleB                                   PENDING
TEST A roleB prohibited actions denied                   PENDING
TEST B roleB -> roleC                                    PENDING
TEST C roleC -> target bucket                            PENDING
TEST D roleC -> other bucket denied                      PENDING
TEST E unauthorized principal -> roleC denied            PENDING
Actual console/CLI authentication                        PENDING
Real PGP-encrypted login profile (valid key)             PENDING
```

---

## 2. REAL AWS POC (pending - requires Account A and Account B)

### Apply order

```powershell
Set-Location C:\work\aws-terraform-devops-assignment\account-a
$env:AWS_PROFILE = 'account-a'
terraform init -backend-config=backend.hcl
terraform apply

Set-Location ..\account-b
$env:AWS_PROFILE = 'account-b'
terraform init -backend-config=backend.hcl
terraform apply
```

Account A goes **first**: IAM rejects a trust policy whose principal does not exist
(`MalformedPolicyDocument: Invalid principal in policy`), so roleB must exist
before roleC.

### Provisioning group2 credentials (out of band, never in Terraform state)

Console password, created by an administrator (the user must change it at first sign-in):

```powershell
$env:AWS_PROFILE = 'account-a'
aws iam create-login-profile --user-name developer1 --password '<temporary-strong-password>' --password-reset-required
```

Type the temporary password only here and share it through a secure channel. Or
set `console_pgp_key` before `terraform apply` and decrypt `console_encrypted_passwords`
offline instead.

After signing in, the user enables a virtual MFA device and, if CLI access is
needed, creates their **own** access key. The group2 self-service policy allows
this for their own user only: IAM console > Security credentials, or AWS CloudShell:

```powershell
aws iam create-access-key --user-name developer1
```

Trying the same for another user (`--user-name developer2`) must fail with `AccessDenied`.

### Temporary credentials for engine (test only)

Terraform does not create access keys. For the test, an administrator creates one
and deletes it afterwards:

```powershell
$env:AWS_PROFILE = 'account-a'
aws iam create-access-key --user-name engine --query "AccessKey.[AccessKeyId]" --output text
aws configure --profile engine
```

Paste the key ID and secret only into `aws configure` (stored in `~/.aws`, never in
the repo). Delete the key at the end of section 2.

Helper to switch the shell to temporary role credentials:

```powershell
function Use-RoleCredentials($Json) {
    $c = ($Json | ConvertFrom-Json).Credentials
    Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
    $env:AWS_ACCESS_KEY_ID = $c.AccessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $c.SecretAccessKey
    $env:AWS_SESSION_TOKEN = $c.SessionToken
}
function Clear-RoleCredentials {
    Remove-Item Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY, Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
}
```

### TEST A - assume roleB

```powershell
$a = aws sts assume-role --profile engine --role-arn arn:aws:iam::000000000000:role/roleB --role-session-name test-a --output json
Use-RoleCredentials $a
aws sts get-caller-identity
```

Expected: `"Arn": "arn:aws:sts::000000000000:assumed-role/roleB/test-a"`.

Negative check, still holding **roleB** credentials:

```powershell
aws s3 ls
aws ec2 describe-instances --region us-east-1
aws iam list-users
```

Expected: `AccessDenied` / `UnauthorizedOperation` for all three. roleB can only assume roleC.

### TEST B - roleB assumes roleC (cross-account)

```powershell
$b = aws sts assume-role --role-arn arn:aws:iam::111111111111:role/roleC --role-session-name cross-account-test --output json
Use-RoleCredentials $b
aws sts get-caller-identity
```

Expected: **SUCCESS**, `"Arn": "arn:aws:sts::111111111111:assumed-role/roleC/cross-account-test"`.

### TEST C - roleC uses the target bucket

```powershell
$t = 'aws-terraform-devops-assignment-crossacct-111111111111'
'hello from roleC' | Out-File -Encoding ascii poc.txt
aws s3 cp poc.txt "s3://$t/poc/poc.txt"
aws s3 ls "s3://$t/poc/"
aws s3 cp "s3://$t/poc/poc.txt" poc-downloaded.txt
aws s3 rm "s3://$t/poc/poc.txt"
```

Expected: **SUCCESS** for upload, list (bucket ARN), download and delete (object ARN).

### TEST D - roleC tries another bucket

```powershell
aws s3 ls "s3://aws-terraform-devops-assignment-control-111111111111"
aws s3 cp poc.txt "s3://aws-terraform-devops-assignment-control-111111111111/x.txt"
aws s3 ls
```

Expected: **AccessDenied** for all three (the last one is `s3:ListAllMyBuckets`, which is not granted).

### TEST E - unauthorized Account-A principal tries roleC

```powershell
Clear-RoleCredentials
aws sts assume-role --profile engine --role-arn arn:aws:iam::111111111111:role/roleC --role-session-name test-e
```

Also, as roleA (developer1 with MFA assumes roleA first; roleA has `sts:AssumeRole` on `*`):

```powershell
aws sts assume-role --profile developer1 --role-arn arn:aws:iam::000000000000:role/roleA --role-session-name test-e-a --serial-number arn:aws:iam::000000000000:mfa/developer1 --token-code 123456
```

Replace `123456` with the current MFA code. Then with the roleA credentials:

```powershell
aws sts assume-role --role-arn arn:aws:iam::111111111111:role/roleC --role-session-name test-e-b
```

Expected (both): `AccessDenied ... is not authorized to perform: sts:AssumeRole on
resource: arn:aws:iam::111111111111:role/roleC`. engine fails on both sides
(identity and trust). roleA passes its own identity side but fails roleC's trust policy.

### Extra checks

```powershell
aws iam get-login-profile --user-name engine
aws iam get-login-profile --user-name ci
aws iam get-login-profile --user-name developer1
aws iam list-attached-role-policies --role-name roleB
aws iam list-role-policies --role-name roleB
```

Expected: `NoSuchEntity` for engine and ci (no console), a profile for developer1,
no attached policies on roleB, and one inline policy (`roleB-assume-roleC-only`).

As roleA: `aws iam list-users` gives `AccessDenied` (explicit deny), and
`aws ec2 describe-instances` succeeds.

Optional: `aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document file://policy.json`
on each rendered policy (`terraform show -json` exposes them).

### Cleanup of test credentials

```powershell
Clear-RoleCredentials
$env:AWS_PROFILE = 'account-a'
aws iam list-access-keys --user-name engine
aws iam delete-access-key --user-name engine --access-key-id <KEY_ID>
Remove-Item poc.txt, poc-downloaded.txt
```

### Real-AWS evidence

```
Date:
Accounts (last 4 digits only):
TEST A engine -> roleB          :
TEST B roleB -> roleC           :
TEST C roleC -> target bucket   :
TEST D roleC -> other bucket    :
TEST E unauthorized -> roleC    :
Console/CLI authentication      :
PGP login profile (valid key)   :
Extra: engine/ci no console     :
Extra: roleB no other access    :
Extra: roleA IAM denied         :
POC-3 (REAL AWS)                :
```
