# FINAL CHECKLIST - Assignment Traceability and Submission Gate

Audited commit: `4f55c4f` (`test: demonstrate and fix iam policy bugs`)
Audit date: 2026-09-29. Terraform v1.5.4, hashicorp/aws v6.66.0, Windows PowerShell 5.1.

Authority: the original assignment (master prompt), checked line by line against
the **committed** Terraform, tests and documentation, not only against POC summaries.

## How to read the Status column

| Status | Meaning |
|---|---|
| **PASS** | Verified in committed code/docs, plus a local test where applicable |
| **LOCAL PASS** | Terraform structure/logic proven locally (validate, offline plan with zero AWS calls, IAM policy **model**). Behavior in real AWS **not yet executed** |
| **AWS PENDING** | Needs real AWS accounts. Procedure written in `tests/taskN-test.md`, **not executed** |

A PENDING real-AWS item is never counted as PASS.

---

## 1. Requirements traceability

### Task 0 - Repository bootstrap

| Requirement | Implementation | File | How tested | Expected result | Status |
|---|---|---|---|---|---|
| Repository structure as specified | All 43 required paths committed (plus justified additions: scripts, fixtures, lock files, `.gitattributes`) | repo tree | `git ls-tree` vs required list (audit) | 0 missing | PASS |
| `.gitignore` protects state, credentials, tfvars, `.terraform`, overrides | Ignore rules incl. `*.tfstate*`, `*.tfvars`, `backend.hcl`, `*.pem`, `*.key`, `.env`, `*override.tf`, generated POC logs | `.gitignore` | `validate-local.ps1` hygiene; audit history scan | nothing forbidden tracked, in HEAD **or any commit** | PASS |
| Terraform + AWS provider version constraints | `>= 1.5.0, < 2.0.0`; `hashicorp/aws ~> 6.0` (module `>= 6.0, < 7.0`) | `*/versions.tf` | `terraform init` / `validate` | valid | PASS |
| Safe CI: fmt + init/validate, no apply, no AWS keys | Workflow: hygiene, `fmt -check -recursive`, `init -backend=false` + `validate` for 3 root modules; `contents: read` | `.github/workflows/terraform-validate.yml` | static review + local simulation (section 5) | no credentials/plan/apply | PASS (GitHub run: after push) |
| Explain why state / credentials / tfvars / `.terraform` are not committed | Written answers | `NOTES.md` (Task 0) | review | all four explained | PASS |

### Task 1 - Multi-instance EC2

| Requirement | Implementation | File | How tested | Expected result | Status |
|---|---|---|---|---|---|
| Five EC2 instances from ONE input variable | `var.instances` `map(object)`; `for_each`; no per-server resource blocks | `modules/ec2/variables.tf`, `modules/ec2/main.tf`, `account-a/ec2.tf` | POC-1 offline plan | exactly 5 `aws_instance` creates | LOCAL PASS |
| Different instance type per instance | t3.micro / small / medium / large / xlarge | `account-a/terraform.tfvars.example` | POC-1 "five different instance types" | 5 distinct | LOCAL PASS |
| Different root volume size per instance | 20 / 30 / 50 / 80 / 100 GiB | same | POC-1 per-instance assertions | exact sizes | LOCAL PASS |
| Different key pair per instance | web01-key ... web05-key | same | POC-1 "five different key pairs" | 5 distinct | LOCAL PASS |
| Different root volume type per instance | gp3, gp2, io2, gp3 (6000 IOPS / 250 MiB/s), io1 | same | POC-1 per-instance assertions | as configured | PASS, interpretation noted (see 3.1) |
| At least one io1/io2 | web03 io2 (3000 IOPS), web05 io1 (4000 IOPS) | same | POC-1 "at least one io1/io2" | 2 present | LOCAL PASS |
| AWS/Terraform validity of volume configs | Validation blocks: boot-capable types only (st1/sc1 rejected), size ranges, IOPS:GiB ratios, gp3 throughput | `modules/ec2/variables.tf` | POC-1: 7 negative fixtures | each rejected with its message | LOCAL PASS |
| Name / Environment / Owner tags | Merged tags on instance and root volume | `modules/ec2/main.tf` | POC-1 per-instance tag assertions | all present | LOCAL PASS |
| `ami_id` variable, no region-specific hard-coded AMI | `ami_id` has no default; AMI lookup documented | `account-a/variables.tf`, README section 6 | review | no hard-coded AMI | PASS |
| Outputs `instance_ids` / `private_ips` maps | name => id / name => private IP | `account-a/outputs.tf`, `modules/ec2/outputs.tf` | POC-1 output-key assertions | keyed web01..web05 | LOCAL PASS |
| Valid `prevent_destroy` on the critical instance, still data-driven | Two filtered `for_each` blocks; `aws_instance.protected` has `prevent_destroy = true` (+ `disable_api_termination`) | `modules/ec2/main.tf` | POC-1: dynamic lifecycle rejected; `terraform_data` mechanism demo | invalid form rejected; protected destroy blocked | LOCAL PASS |
| Real EC2 apply / describe / destroy-blocked evidence | Procedure R1-R7 | `tests/task1-test.md` | not executed | - | AWS PENDING |

### Task 2 - Remote state and locking

| Requirement | Implementation | File | How tested | Expected result | Status |
|---|---|---|---|---|---|
| Explain local-state problems for two engineers | Q2 | `NOTES.md` | review | concrete failure modes | PASS |
| Bootstrap stack for the chicken-and-egg problem | Local-state stack creating bucket + table | `bootstrap/main.tf` | POC-2 offline plan | 8 resources planned | LOCAL PASS |
| S3 versioning / SSE / public access block | Versioning Enabled; AES256 (KMS option); all 4 PAB flags; ACLs disabled; TLS-only policy; lifecycle | `bootstrap/main.tf` | POC-2 assertions | all settings | LOCAL PASS |
| Protections for state infrastructure | `prevent_destroy` (bucket + table), `force_destroy = false`, DynamoDB deletion protection, PITR | `bootstrap/main.tf` | POC-2 | present | LOCAL PASS |
| DynamoDB lock table (implemented as required) | `LockID` (S) hash key, on-demand | `bootstrap/main.tf`, `*/backend.hcl.example` | POC-2 | table + backend config | LOCAL PASS |
| S3 backend with separate keys | `account-a/terraform.tfstate`, `account-b/terraform.tfstate`; partial config | `account-a/backend.tf`, `account-b/backend.tf` | POC-2 backend checks; no-credential init fails, no local fallback | distinct keys, consistent names | LOCAL PASS |
| Explain `init` / `-migrate-state` / `-reconfigure` | Table | `NOTES.md`, README section 7 | review | all three explained | PASS |
| Mention newer native S3 locking | Informational only (`use_lockfile`, 1.10+); not a replacement | `NOTES.md` | review | present | PASS |
| Two competing operations against real S3/DynamoDB | Procedure R6 (lock error, then `-lock-timeout` wait) | `tests/task2-test.md` | not executed (local demo proves only that a competing **local**-state writer is refused) | - | AWS PENDING |

### Task 3 - Multi-account IAM

| Requirement | Implementation | File | How tested | Expected result | Status |
|---|---|---|---|---|---|
| group1 = engine, ci; CLI/programmatic only | Exclusive membership; no login profile ever | `account-a/iam-users-groups.tf` | POC-3 | members exact; 0 login profiles | LOCAL PASS |
| group2 = two named users; console + CLI | developer1/developer2; self-service password/keys/MFA scoped to `${aws:username}`; roleA via MFA | `account-a/iam-users-groups.tf` | POC-3 | access model configured | LOCAL PASS (see 3.2) |
| No secret access keys in outputs | No `aws_iam_access_key`; no plaintext password in state or outputs | `account-a/*.tf` | POC-3 | 0 keys, 0 plaintext outputs | LOCAL PASS |
| roleA = admin except IAM, not AdministratorAccess | `Allow NotAction iam:*` + explicit `Deny iam:*` | `account-a/role-a.tf` | POC-3 structure + model | IAM denied, other services allowed | LOCAL PASS |
| roleB ONLY `sts:AssumeRole` on roleC | One inline statement, exact roleC ARN, no managed policies | `account-a/role-b.tf` | POC-3 | exactly that | LOCAL PASS |
| roleC trusts ONLY `role/roleB` (not root, not user) | Exact principal | `account-b/role-c.tf` | POC-3 | 1 principal, no `:root`, no `:user/` | LOCAL PASS |
| roleC full access to ONE bucket (bucket + `bucket/*`) | `s3:*` on both ARNs only | `account-b/role-c.tf`, `account-b/s3.tf` | POC-3 structure + model (tests C/D) | target allowed, others denied | LOCAL PASS |
| Tests A-E (assume, cross-account, target, other bucket, unauthorized) | Model on rendered policies; real procedure written | `scripts/task3-local-poc.ps1`, `tests/task3-test.md` | POC-3 model (not AWS) | as expected | LOCAL PASS / AWS PENDING |
| Q4 / Q5 / Q6 written answers | Long-lived keys, alternatives, root vs exact ARN | `NOTES.md` | review | answered | PASS |

### Task 4 - CI least-privilege policy

| Requirement | Implementation | File | How tested | Expected result | Status |
|---|---|---|---|---|---|
| Custom policy, no broad managed policies | `ci-least-privilege` attached to `ci` user only | `account-a/ci-policy.tf` | POC-4 structure; broad-policy scan | none attached | LOCAL PASS |
| Push to ONE ECR repository | 6 push actions on exact repo ARN; `GetAuthorizationToken` on `*` (required) | same | POC-4 matrix A-D | push allowed; other repo/delete denied | LOCAL PASS |
| Deploy ONE ECS service | `RegisterTaskDefinition` on `*` (required); `UpdateService`/`DescribeServices` on exact service ARN | same | POC-4 matrix E-G | target allowed; others denied | LOCAL PASS |
| Scoped `iam:PassRole` | Exact execution- and task-role ARNs + `iam:PassedToService = ecs-tasks.amazonaws.com` | same | POC-4 matrix H-K | only those roles, only to ECS tasks | LOCAL PASS |
| Read ONE artifact bucket, read-only | `ListBucket` on bucket, `GetObject` on `bucket/*` | same | POC-4 matrix L-O | read only | LOCAL PASS |
| Wildcards only where AWS requires them | 2 isolated single-action statements | same, `policies/README.md` | POC-4 wildcard review | only the 2 documented | LOCAL PASS |
| Reference JSON matches Terraform | `policies/ci-policy.json` | `policies/` | POC-4 drift check (mutation-tested) | identical | PASS |
| Q7 / Q8 excluded permissions and why | Written answers | `NOTES.md` | review | answered | PASS |
| Real ECR push / ECS deploy / PassRole / S3 read / negatives | Procedure A-Q | `tests/task4-test.md` | not executed | - | AWS PENDING |

### Task 5 - Find and fix the bugs

| Requirement | Implementation | File | How tested | Expected result | Status |
|---|---|---|---|---|---|
| BUG 1: `user/roleB` -> `role/roleB` | Fixed trust is the Task 3 code; broken version kept as a fixture only | `account-b/role-c.tf`, `tests/fixtures/task5/` | POC-5 | broken trust denies roleB; fixed allows | PASS |
| BUG 2: `s3:*` on `*` -> bucket + `bucket/*` | Same | same | POC-5 | broken policy over-broad; fixed scoped | PASS |
| Deployable code contains neither bug | Code-line scan + rendered policies | `*.tf` | POC-5 | none | PASS |
| Fixed fixtures match Terraform (no drift) | Normalized comparison | `tests/fixtures/task5/fixed-*.json` | POC-5 | identical | PASS |
| Q9 / Q10 written answers | Wrong principal type; bucket-level vs object-level ARNs | `NOTES.md` | review | answered | PASS |
| Real before/after tests | Disposable `roleC-bugtest` procedure | `tests/task5-test.md` | not executed | - | AWS PENDING |

### Documentation deliverables

| Requirement | Implementation | File | How tested | Expected result | Status |
|---|---|---|---|---|---|
| README sections 1-17 with Mermaid diagrams | All 17 sections; 6 Mermaid diagrams | `README.md` | audit | complete | PASS |
| NOTES answers every written question | Q1-Q10 plus Task 0 answers | `NOTES.md` | audit (topic scan) | 10/10 | PASS |
| Per-task test procedures (positive + negative) | `tests/task0-5-test.md` | `tests/` | review | local evidence + real-AWS steps | PASS |
| docs: architecture / testing / troubleshooting | Present; testing and troubleshooting cover Tasks 0-5 | `docs/` | review | present | PASS (architecture refresh recommended, see 5) |

---

## 2. Written answers (NOTES.md)

| # | Question | Answer (summary) | Status |
|---|---|---|---|
| Q1 | Which EC2 instance is protected and why? | web03 (prod, io2); `prevent_destroy` + termination protection; what happens on destroy | PASS |
| Q2 | Local state with multiple engineers? | duplicates, overwrites, destructive plans, orphans, no concurrency control | PASS |
| Q3 | How do S3 remote state and locking help? | single state per key, DynamoDB conditional lock, versioning, encryption | PASS |
| Q4 | Long-lived engine/ci keys in production? | No, with reasons | PASS |
| Q5 | What instead? | OIDC for CI, compute roles, Identity Center, role assumption | PASS |
| Q6 | Why is Account A root broader than the roleB ARN? | root delegates to every sufficiently privileged Account A principal | PASS |
| Q7 | What was excluded from CI? | table of excluded permissions | PASS |
| Q8 | Why excluded? | per-category rationale | PASS |
| Q9 | Why was the roleC trust broken? | roleB is a role; the ARN names a user | PASS |
| Q10 | Why was `Resource "*"` wrong? | over-broad; bucket-level vs object-level ARNs | PASS |

---

## 3. Interpretations and scope decisions (explicit, not hidden)

### 3.1 Task 1 - "different root volume type" per instance

The assignment lists "root volume type" among the attributes that must differ,
but its own example configuration uses **gp3 twice** (web01 and web04). This
implementation follows the example: 4 distinct types across 5 instances
(gp3, gp2, io2, gp3, io1). web04's gp3 is a different volume configuration
(6000 IOPS / 250 MiB/s provisioned vs web01's baseline).

Five fully distinct types would force one instance onto `standard` (magnetic,
previous generation), because st1/sc1 cannot be boot volumes. That was
deliberately not done. Decision: example governs; no Terraform change.

### 3.2 Task 3 - group2 "console + CLI capability"

Authorization for console + CLI is configured (self-service password, access
keys and MFA on the user's own identity; roleA with MFA). **Credential
provisioning is intentionally kept out of Terraform state.** No access keys are
ever created. Console login profiles are created only when `console_pgp_key` is
set, and then only the PGP-encrypted password is stored or output. The real
provisioning procedure is in `tests/task3-test.md` (AWS PENDING).

### 3.3 Task 4 - policy only

The ECR repository, ECS cluster/service, task roles and artifact bucket are named
by variables and **not created** by this repository. The assignment asks for the
CI policy, not the application.

### 3.4 Local POC evidence limits

- Offline plans prove Terraform logic and rendered policies, not AWS acceptance.
- `scripts/IamPolicyModel.psm1` is a simplified evaluator (**POC model only**): no
  SCPs, permission boundaries or session policies, and condition values are
  compared case-insensitively (AWS `StringEquals` is case-sensitive).
- Mechanism demos (`terraform_data`, local-backend lock) are labelled as such and
  are never presented as AWS evidence.

---

## 4. Security and least-privilege review

Scanned: all 26 deployable `.tf` files at `4f55c4f` (code lines, comments excluded)
plus git history.

| Pattern | Hits | Assessment |
|---|---|---|
| `Resource "*"` | 5 | `ecr:GetAuthorizationToken`, `ecs:RegisterTaskDefinition` (AWS requires `*`; each isolated as a single-action statement and documented); `iam:GetAccountPasswordPolicy` (no resource type); roleA `Allow NotAction iam:*` (required admin role); roleA `Deny iam:*` (restricts) |
| `Principal "*"` | 2 | both in `Deny` statements (`DenyInsecureTransport`); they restrict access |
| `Action "*"` | 0 | - |
| `s3:*` | 3 | roleC on bucket + `bucket/*` only (as required); 2x TLS `Deny` |
| `iam:*` | 2 | roleA `NotAction` + `Deny` (the "except IAM" design) |
| `AdministratorAccess` | 0 | not used anywhere |
| `:root` | 0 | no account-root trust |
| `user/roleB` | 0 | only in comments and Task 5 fixtures (test data) |
| `aws_iam_access_key` | 0 | no Terraform-managed keys |
| password / secret outputs | 1 | `console_encrypted_passwords`: PGP-encrypted only, empty by default |
| hardcoded credentials / AWS key IDs / private keys | 0 | - |
| `*.tfstate`, `terraform.tfvars`, `backend.hcl`, `*.pem`, `*.key`, `.env`, POC logs | 0 | not tracked at HEAD and never in history |

**Security review: PASS. Least-privilege review: PASS.** All wildcards are either
required by AWS (and isolated) or are restricting `Deny` statements.

---

## 5. GitHub Actions review

| Item | Classification | Result |
|---|---|---|
| Triggers `pull_request` + push to `main` | Required for submission | PASS |
| `terraform fmt -check -recursive` | Required | PASS |
| `init -backend=false` + `validate` for bootstrap / account-a / account-b (`modules/ec2` via account-a) | Required | PASS |
| No AWS credentials, no `plan`, no `apply`; `permissions: contents: read` | Required | PASS |
| Secret / state hygiene job | Required (repo safety) | PASS |
| Future OIDC flow explained (GitHub OIDC -> IAM role -> temporary STS credentials) | Required (explanation) | PASS - NOTES.md Q5, README section 15 |
| Workflow steps simulated locally in a clean clone | Evidence | PASS - hygiene job steps run verbatim in Git Bash (both exit 0); fmt and `init -backend=false` + `validate` covered by the clean-clone regression (Terraform 1.5.4, inside the workflow's `~1.5.0` range) |
| Actual GitHub Actions run | After push | PENDING (repository not yet pushed) |
| Windows job running `scripts/run-regression.ps1` (PowerShell POCs) | Recommended improvement | not added |
| Dedicated README section with an OIDC diagram | Recommended improvement | not added (explanation is in NOTES Q5) |
| Refresh `docs/architecture.md` with the Task 2-5 additions | Recommended improvement | not added (README covers them) |
| `plan` / `apply` via OIDC with environments and approvals | Real-AWS only | out of scope (deliberately not automated) |

---

## 6. Clean-clone reproducibility

A fresh `git clone` of the repository into `%TEMP%\aws-terraform-assignment-final-audit`
(the working repository was not touched), then `scripts\run-regression.ps1`:

```
HEAD                                     4f55c4f
git status --short                       (empty)
.terraform dirs in fresh clone           0
ignored files in fresh clone             0

terraform fmt -check -recursive          PASS
terraform validate bootstrap             PASS
terraform validate account-a             PASS
terraform validate account-b             PASS
POC-1   PASS  exit=0 realFails=0 (3 expected negative-test Error: lines)
POC-2   PASS  exit=0 realFails=0 (3 expected negative-test Error: lines)
POC-3   PASS  exit=0 realFails=0
POC-4   PASS  exit=0 realFails=0  8/8
POC-5   PASS  exit=0 realFails=0  15/15
Raw logs captured                        PASS
New TEMP workspaces remaining = 0        PASS
validate-local / hygiene                 PASS
git diff --check                         PASS
REAL AWS POCs                            PENDING
LOCAL REGRESSION: PASS
```

The same regression in the working repository gave POC-3 23/23 (counted from
its raw log). The clean clone needed only committed files plus a provider download
from registry.terraform.io.

---

## 7. Real AWS validation (not executed)

All real-AWS procedures are written, with expected outputs and evidence templates:

| Task | Procedure | Status |
|---|---|---|
| 1 | EC2 apply, describe, destroy-blocked, termination protection | AWS PENDING |
| 2 | Bootstrap, backend migration, two-terminal DynamoDB lock contention | AWS PENDING |
| 3 | Tests A-E, console/CLI authentication, valid-key PGP login profile | AWS PENDING |
| 4 | ECR push, ECS register/deploy, PassRole, S3 read, negatives A-Q | AWS PENDING |
| 5 | Broken-then-fixed trust and S3 policies on a disposable role | AWS PENDING |

The submission is complete as **Terraform code, design, documentation and local
validation**. Real-AWS execution is a remaining validation gap. It is documented
and not claimed as done.

---

## 8. FINAL SUBMISSION GATE

```
FINAL SUBMISSION GATE                     (audited commit 4f55c4f)
────────────────────────────────────────
Assignment requirements mapped       PASS   (sections 1-2; interpretations in 3)
Tasks 1-5 implementation             PASS
NOTES questions answered             PASS   (Q1-Q10 + Task 0)
Security review                      PASS   (section 4)
Least privilege review               PASS   (wildcards required-by-AWS or Deny only)
Clean-clone regression               PASS   (section 6)
GitHub Actions review                PASS   (static + local simulation; GitHub run after push)
README completeness                  PASS   (17 sections, 6 Mermaid diagrams)
No secrets/state committed           PASS   (HEAD and full history)
Working tree clean                   PASS   (at 4f55c4f; this checklist is committed on top)

LOCAL POC                            PASS
REAL AWS POC                         PENDING

OVERALL
READY FOR SUBMISSION                 YES, as Terraform code + design + documentation +
                                     local validation. Real-AWS execution is a documented,
                                     unexecuted validation gap, not claimed as PASS.
```

Before submitting: push, confirm the GitHub Actions run is green, and check
that README / Mermaid / this checklist render and that no local files appear on GitHub.
