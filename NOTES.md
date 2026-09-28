# NOTES - Assignment Answers

> Local validation only so far. Real-AWS evidence will be added when an account is available.

## Task 0 - Repository hygiene

### Why state files must never be committed

- State stores every managed attribute in plain text, including secrets such as
  `aws_iam_access_key.secret`, database passwords, generated private keys and
  instance IPs. Git history is permanent: a secret removed in a later commit is
  still readable in earlier ones.
- State is the single source of truth. Git copies go stale immediately, two
  branches produce conflicting "truths", and merging JSON state corrupts it.
- Git provides no locking, so two engineers can apply concurrently. The fix is the
  S3 backend with DynamoDB locking (Task 2).

### Why credentials must never be committed

- Automated scanners find AWS keys pushed to public GitHub within minutes and abuse
  them (crypto-mining, data theft).
- Removing a key from the latest commit does not remove it from history, forks or
  clones. The only fix is to rotate/deactivate the key.
- Humans should use short-lived credentials (IAM Identity Center / `aws sso login`,
  assumed roles); CI should use OIDC. Neither needs a stored key.

### Why terraform.tfvars may contain sensitive values

- It holds real, environment-specific values: account IDs, emails, allowed CIDRs,
  and sometimes passwords or tokens. It is not reviewed like code and differs per
  engineer and environment.
- Only `terraform.tfvars.example` with placeholder values is committed. Real secrets
  should come from Secrets Manager / SSM Parameter Store or `TF_VAR_*` environment
  variables.

### Why .terraform/ must not be committed

- It contains provider binaries (the AWS provider v6.66.0 for Windows is 876,995,208 bytes, ~836 MiB) that are
  platform-specific: a Windows `.exe` is useless on the Linux CI runner, and it
  exceeds GitHub's 100 MB file limit.
- It contains cached backend configuration (bucket, key, and sometimes values
  passed through `-backend-config`).
- `terraform init` recreates it. What IS committed is `.terraform.lock.hcl`, which
  pins exact provider versions and hashes so everyone uses the same build.

## Assignment questions

| # | Question | Answered in |
|---|---|---|
| 1 | Which EC2 instance is protected and why? | [Answered below](#q1---which-ec2-instance-is-protected-and-why) |
| 2 | What happens with local state when multiple engineers operate on the same infrastructure? | [Answered below](#q2---what-happens-with-local-state-when-multiple-engineers-operate-on-the-same-infrastructure) |
| 3 | How do S3 remote state and locking help? | [Answered below](#q3---how-do-s3-remote-state-and-locking-help) |
| 4 | Would engine/ci long-lived access keys be used in real production? | [Answered below](#q4---would-engineci-long-lived-access-keys-be-used-in-real-production) |
| 5 | What should be used instead? | [Answered below](#q5---what-should-be-used-instead) |
| 6 | Why is trusting Account A root broader than trusting the roleB ARN? | [Answered below](#q6---why-is-trusting-account-a-root-broader-than-trusting-the-roleb-arn) |
| 7 | What permissions were deliberately excluded from CI? | [Answered below](#q7---what-permissions-were-deliberately-excluded-from-ci) |
| 8 | Why were those permissions excluded? | [Answered below](#q8---why-were-those-permissions-excluded) |
| 9 | Why was the original roleC trust policy broken? | [Answered below](#q9---why-was-the-original-rolec-trust-policy-broken) |
| 10 | Why was `Resource "*"` wrong for roleC S3 permissions? | [Answered below](#q10---why-was-resource--wrong-for-rolec-s3-permissions) |

## Task 1 - Multi-instance EC2

### Q1 - Which EC2 instance is protected and why?

**web03** is protected. It is the critical **production** instance: it is the only
one tagged `Environment = prod`, and it runs on the **io2** volume (the most
expensive, highest-durability storage in the set, chosen for a production
workload). Losing it would cause an outage and data loss, while web01/02/04/05
are dev instances that can be recreated from code at any time.

It is marked in data, not in code: `protected = true` in `var.instances`.

**What `prevent_destroy` does.** It is a Terraform lifecycle meta-argument. When
any plan (`plan`, `apply`, `destroy`) would destroy that resource, Terraform
aborts the WHOLE plan before calling AWS:

```
Error: Instance cannot be destroyed
Resource module.ec2.aws_instance.protected["web03"] has lifecycle.prevent_destroy
set, but the plan calls for this resource to be destroyed.
```

This covers:

- `terraform destroy`
- removing web03 from `var.instances`
- any change that forces replacement (`-/+`), such as a new AMI, `key_name` or subnet

In-place updates (such as instance type, tags, or root volume size/IOPS) still work.
Nothing in AWS is touched when the error fires, and the other instances aren't
destroyed either, because the whole run stops.

**Limits of prevent_destroy (why termination protection is added too).**
- It only protects against Terraform. The console, the CLI or another tool can still
  terminate the instance. `disable_api_termination = true` closes that gap: AWS
  rejects `TerminateInstances` with `OperationNotPermitted`.
- If someone deletes the resource block (or the `lifecycle` block) from the code,
  the guard is gone. Code review and branch protection cover that risk.

### Why not `prevent_destroy = each.value.protected`?

Terraform processes `lifecycle` while loading configuration, before `for_each` and
`each` exist, so it only accepts literal values. The local POC proves this:
Terraform 1.5.4 returns `Error: Variables not allowed` for that line.

**Valid design:** one `map(object)` input, split by two `for` filters into
`aws_instance.standard` (protected = false) and `aws_instance.protected`
(protected = true, `prevent_destroy = true`). Both use `for_each` over the same data.

| Option | Verdict |
|---|---|
| `prevent_destroy = each.value.protected` | Invalid, Terraform rejects it |
| Five hard-coded `aws_instance` blocks | Violates the assignment and is not data-driven |
| `prevent_destroy = true` on one for_each block | Protects ALL five, so dev instances can't be cleaned up |
| **Two for_each blocks over one filtered map** | **Chosen**: valid, data-driven, protects only the critical instance |

**Tradeoffs:**
1. Two near-identical resource blocks must be kept in sync.
2. Switching an instance between groups changes its state address. Use a `moved`
   block, or Terraform plans a destroy/create (blocked for protected instances, which
   is the intended safety).
3. Protection is per group, not per instance. That's acceptable because "protected"
   is exactly one boolean.

### Volume configuration decisions

- The requested examples were validated against AWS limits (size ranges, IOPS:GiB
  ratios, which types can boot). All were valid.
- web03 io2 50 GiB with 3000 IOPS: the io2 max is 1000 IOPS/GiB, so 50000, and 3000 is valid.
- web05 "another valid configuration": st1/sc1 were ruled out because HDD types
  cannot be boot volumes, and `standard` because it is previous generation.
  **io1 100 GiB / 4000 IOPS** was chosen (the io1 max is 50/GiB, so 5000).
- web04 gp3 with 6000 IOPS and 250 MiB/s makes it a different configuration from
  web01's baseline gp3.
- The rules are enforced by `validation` blocks. Seven negative fixtures prove that
  bad inputs fail at plan time, before any AWS call.

## Task 2 - Remote state and locking

### Q2 - What happens with local state when multiple engineers operate on the same infrastructure?

```
Developer A (laptop A: terraform.tfstate v1) ----\
                                                   >---> SAME AWS account
Developer B (laptop B: terraform.tfstate v1) ----/
```

Each engineer has a **private, divergent copy** of the truth, and Terraform trusts
whichever copy it reads. Concretely:

1. **Duplicate resources.** A applies and creates web01. B's state doesn't know
   about it, so B's apply creates a *second* web01 (or fails on a name clash, for
   uniquely named resources like S3 buckets and IAM roles).
2. **Silent overwrites / drift.** A changes web04 to t3.xlarge. B, with the old
   state and code, plans "t3.large -> no change", or reverts A's change on the next apply.
3. **Destructive plans.** B removes something from the code that only B's state
   tracks, or B's state is older than reality. Terraform plans destroys of resources
   A depends on, and nobody sees the full picture in either plan.
4. **Orphaned resources.** Resources recorded only in A's state become invisible
   to B. If A's laptop dies, nobody can manage or destroy them with Terraform again.
5. **No concurrency control.** Two applies run at the same time against the same
   resources. API calls interleave, and the state written last wins, so whatever
   the other apply created is lost from state.
6. **Secrets on laptops.** Every copy of state holds sensitive values in plain
   text, outside any access control or audit trail.

Sharing the file through Git or a network drive doesn't fix this. Git has no
locking, merge conflicts corrupt JSON state, and copies go stale immediately.

### Q3 - How do S3 remote state and locking help?

| Problem | Solved by |
|---|---|
| Divergent copies | **One** state object per stack in S3 (`account-a/terraform.tfstate`, `account-b/terraform.tfstate`). Every engineer and pipeline reads and writes the same object. |
| Concurrent applies | **DynamoDB lock**. Before any state-changing operation, Terraform does a *conditional* PutItem of `LockID = "<bucket>/<key>"`. A second process fails with `Error acquiring the state lock` (Lock Info shows who and when), or waits with `-lock-timeout`. The lock is deleted when the operation ends. |
| Bad write / corruption / accidental delete | **S3 versioning**. Every write is a new version, so any earlier state can be restored. The lifecycle rule keeps the newest 10 old versions and expires older ones after 90 days. |
| Secrets in state | **SSE** (AES256, or KMS via `kms_key_arn`), `encrypt = true` in the backend, TLS-only bucket policy, all public access blocked, ACLs disabled. Access is controlled by IAM and auditable with CloudTrail. |
| Losing the state store | `prevent_destroy` on bucket and table, `force_destroy = false`, DynamoDB deletion protection, point-in-time recovery. |
| One stack blocking another | Separate keys mean separate state files and separate lock items. account-a work never blocks account-b. |

Locking does not merge changes. It serializes them, so the second engineer re-plans
against the state the first one wrote.

### The bootstrap problem

A backend must exist before `terraform init` can use it. `bootstrap/` is applied
once with **local** state to create the bucket and table. Only then can
`account-a`/`account-b` run `terraform init -backend-config=backend.hcl`. The small
bootstrap state file is kept safe locally. Optionally, add a backend block to
`bootstrap/` afterwards and run `terraform init -migrate-state` to move its own
state into the bucket it created, under the key `bootstrap/terraform.tfstate`.

### Cross-account state access design

The state bucket lives in **Account A**. The `account-b` backend authenticates with
an Account A profile (`profile = "account-a"` in `backend.hcl`), while its **provider**
uses Account B credentials. This means no cross-account bucket policy is needed,
Account B principals can't read Account A's state, and the aws/s3 KMS key isn't
used across accounts (which would not work).

### terraform init vs -migrate-state vs -reconfigure

| Command | Use when | What happens to existing state |
|---|---|---|
| `terraform init -backend-config=backend.hcl` | First init of a working directory, or after cloning. Also after adding a module or provider. | Nothing to move. Connects to the backend. If it detects a backend change it stops and asks you to choose one of the two below. |
| `terraform init -backend-config=backend.hcl -migrate-state` | You **had** state somewhere (local, or an old bucket/key) and want to **move** it to the new backend. For example, Task 1 was applied with local state and now moves to S3. | **Copies** the state from the old backend to the new one (asks for confirmation). The old copy is left in place, so back it up and then delete it. |
| `terraform init -backend-config=backend.hcl -reconfigure` | Backend settings changed but you do **not** want to move state: the new location already has the correct state, or a fresh clone/CI runner has stale `.terraform/` metadata. | Ignores the previously cached backend configuration and uses the new one. **No state is copied.** Using it by mistake when you meant to migrate makes Terraform see an empty state and plan to create everything again. |
| `terraform init -backend=false` | Local validation and CI (this repo). | Skips the backend completely. Never reads or writes state. |

### Implemented vs informational locking

| Locking approach | Status |
|---|---|
| **S3 backend + DynamoDB `LockID` table** | **IMPLEMENTED, required by the assignment** |
| Native S3 locking (`use_lockfile`) | **INFORMATIONAL ONLY**, not a replacement for the assignment requirement |

For context only: Terraform **1.10** added native S3 locking (`use_lockfile = true`),
which writes a `.tflock` object next to the state using S3 conditional writes.
Terraform **1.11** deprecated the `dynamodb_table` argument in favor of it. This
repository implements the **DynamoDB lock table exactly as the assignment
requires**. That is also the only S3-backend locking in the pinned minimum,
Terraform 1.5. A future migration, outside the assignment's scope, would add
`use_lockfile = true` alongside `dynamodb_table` for a transition period (both locks
taken), then remove the table.

### What the local POC does and does not prove

```
LOCAL POC
Terraform refused a competing local-state writer.        PASS

REAL AWS POC
S3 remote state actually created.                        PENDING
DynamoDB state locking actually exercised.               PENDING
Two concurrent Terraform operations tested against AWS.  PENDING
```

The local lock demo uses the **local** backend. It shows the general Terraform
behavior (a second writer is refused while the first holds the state lock), but it
does **not** prove S3 remote state or DynamoDB locking.

On Windows, the local backend's byte-range file lock also makes the competing process
fail immediately with a file read error instead of retrying, so `-lock-timeout`
waiting can't be shown locally. With DynamoDB, Terraform retries the conditional
`PutItem` until `-lock-timeout` expires. That is test R6 in `tests/task2-test.md`.

## Task 3 - Multi-account IAM

### What was built

| Principal | Account | Access | How |
|---|---|---|---|
| group1: engine, ci | A | CLI/programmatic only | No `aws_iam_user_login_profile`, so no console password exists. Terraform creates **no access keys**. |
| group2: developer1, developer2 | A | Console + CLI (access model) | A group policy lets each user manage only **their own** password, access keys and MFA (`user/${aws:username}`), and assume roleA with MFA. The **credentials themselves are not provisioned into Terraform state**: login profiles are created only when `console_pgp_key` is set (encrypted password only, reset required). Otherwise an administrator creates console passwords out of band, and each user creates their own CLI key if one is needed. |
| roleA | A | Everything except IAM | Custom policy `Allow NotAction iam:*` + `Deny iam:*`. Assumable by developer1/developer2 **with MFA**. |
| roleB | A | Only `sts:AssumeRole` on `arn:aws:iam::111111111111:role/roleC` | One inline statement, no managed policies. Assumable only by `engine`. |
| roleC | B | `s3:*` on one bucket | Trust = exactly `arn:aws:iam::000000000000:role/roleB`. Resources = `arn:aws:s3:::BUCKET` and `arn:aws:s3:::BUCKET/*`. |

The assignment doesn't say who may assume roleA and roleB, so the narrowest
reasonable choice was made. roleA is for humans (group2, MFA required). roleB is
the cross-account entry point for the `engine` workload. `ci` is deliberately
**not** allowed to assume roleB; its permissions come in Task 4.

### Security implications of console + CLI users (group2)

- **Two credential types to protect.** A console password (phishing, reuse) and
  optional access keys (leaks). Mitigations here: reset required at first sign-in,
  and users can only manage their own credentials.
- **MFA is enforced where it matters.** The users' own permissions are
  self-service only. All real work goes through roleA, which requires
  `aws:MultiFactorAuthPresent = true`. A stolen password or key without MFA can't
  reach roleA.
- **Hardening for production** (beyond the assignment): an account password
  policy, a "deny everything unless MFA" guardrail statement, access key
  rotation/age alarms, CloudTrail alerts on console sign-ins without MFA, and
  ideally IAM Identity Center instead of IAM users (see Q5).
- **No plaintext credential ever reaches Terraform state or outputs.** Without a
  PGP key, `aws_iam_user_login_profile` would store the generated password in
  plaintext in state. So Terraform creates login profiles **only** when
  `console_pgp_key` is set, and then stores only `encrypted_password`. By default,
  console passwords are provisioned out of band
  (`aws iam create-login-profile --password-reset-required`), and CLI access keys
  are created by each user through the self-service policy, never by Terraform.
- **What the local POC proves:** the permission model (who may do what) and the
  absence of credentials in state. It deliberately does **not** provision
  credentials; that part is covered by the real-AWS steps in `tests/task3-test.md`.

### roleA - "Allow *, but deny IAM" and explicit Deny

```json
{ "Effect": "Allow", "NotAction": "iam:*", "Resource": "*" }
{ "Effect": "Deny",  "Action":    "iam:*", "Resource": "*" }
```

- `AdministratorAccess` was **not** used: it includes `iam:*`, and a role that can
  edit IAM can grant itself anything, so "except IAM" would be meaningless.
- `Allow NotAction iam:*` grants every action of every service **except** IAM
  actions. On its own, IAM is just *not allowed* (implicit deny).
- **Why the explicit Deny too:** in AWS evaluation, an explicit `Deny` in any
  applicable policy always wins over any `Allow`. If someone later attaches another
  policy that allows `iam:CreateUser` or `iam:AttachRolePolicy`, the explicit Deny
  still blocks it. An implicit deny would be overridden by that new Allow.
- **Tradeoff:** `iam:PassRole` is an IAM action, so roleA can't pass roles
  (for example, attach an instance profile to EC2 or a role to Lambda). That's a
  deliberate consequence of "except IAM". If needed, carve out
  `iam:PassRole` for specific role ARNs with an `iam:PassedToService` condition.
- **Residual paths to consider in production:** services that manage identities
  outside IAM (IAM Identity Center `sso:*`, `organizations:*`) are not IAM actions.
  An SCP or permission boundary should restrict them in a real organization.
- `Resource "*"` is justified here because this *is* the administrator role.

### Two-sided cross-account AssumeRole

```
roleB (Account A)  -- sts:AssumeRole -->  roleC (Account B)
   side 1: roleB IDENTITY policy          side 2: roleC TRUST policy
   Allow sts:AssumeRole                   Allow sts:AssumeRole
   Resource = arn:...:111111111111:       Principal = arn:...:000000000000:
              role/roleC                              role/roleB
```

Both sides must allow the call:

1. **roleB needs permission to call `sts:AssumeRole`** on roleC's ARN (Account A
   controls what its principals may do).
2. **roleC's trust policy must trust roleB** (Account B controls who may enter).

Neither account can grant access alone. The local model shows each side
separately. roleA passes side 1 (it has `sts:AssumeRole` on `*`) but fails side 2,
so it is DENIED. `engine` fails both sides.

### Bucket-level vs object-level ARNs

| ARN | Matches | Needed for |
|---|---|---|
| `arn:aws:s3:::BUCKET` | the bucket itself | `s3:ListBucket`, `s3:GetBucketLocation`, `s3:GetBucketVersioning`, `s3:PutBucketPolicy`, `s3:DeleteBucket` |
| `arn:aws:s3:::BUCKET/*` | every object key in it | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:GetObjectVersion` |

Bucket ARNs never match object keys and vice versa. With only `BUCKET/*`, roleC
could read objects but `aws s3 ls s3://BUCKET` fails. With only `BUCKET`, it could
list but not read or write. "Full access to one bucket" therefore needs **both**,
and nothing broader.

### Q4 - Would engine/ci long-lived access keys be used in real production?

**No, not as the recommended design.** Long-lived IAM user access keys:

- **Never expire.** A leaked key (committed to Git, printed in CI logs, left in a
  laptop's `~/.aws/credentials` or a container image) works until someone notices
  and deletes it.
- **Must be stored somewhere.** Every copy (CI secret store, config file,
  environment variable) is an attack surface, and they spread over time.
- **Need manual rotation**, which is often skipped. Old keys stay active.
- **Are hard to attribute and scope.** One key is often shared by several
  pipelines or hosts, and it can't carry per-run context.

For this reason Terraform here creates **no** access keys for engine and ci, and
the real-AWS POC creates a temporary one for `engine` only for testing, deleted
afterwards. If keys are unavoidable (a third-party system with no federation
support), use one key per system, store it in a secrets manager, rotate it
automatically, restrict it by source IP/VPC conditions, and alarm on its use.

### Q5 - What should be used instead?

| Who | Instead of IAM user + static key | Why |
|---|---|---|
| **CI/CD (ci)** | **OIDC / workload identity federation.** GitHub Actions gets an OIDC token and calls `sts:AssumeRoleWithWebIdentity` on a CI role whose trust policy is restricted to `repo:<org>/<repo>:ref:refs/heads/main` (or an environment). | No secret stored in GitHub. Credentials last minutes and are scoped per repository, branch or environment. |
| **Workloads on AWS (engine)** | **IAM roles for compute**: EC2 instance profile, ECS task role, EKS IRSA / Pod Identity, Lambda execution role. | The SDK gets automatically rotated temporary credentials from the metadata/credential endpoint. Nothing to store. |
| **Workloads outside AWS** | **IAM Roles Anywhere** (X.509 certificate) or OIDC federation. | Temporary credentials tied to a certificate or identity provider. |
| **Humans (developer1/2)** | **IAM Identity Center** (SSO) with MFA, permission sets, and `aws sso login` for the CLI. | Central identity, no IAM users, short-lived CLI credentials, easy offboarding. |
| **Everything** | **Assume IAM roles** that return temporary STS credentials (as roleB/roleC already do). | Credentials expire (1 hour here), every session is logged in CloudTrail with a session name, and access is revoked by editing one trust policy. |

### Q6 - Why is trusting Account A root broader than trusting the roleB ARN?

`"Principal": {"AWS": "arn:aws:iam::000000000000:root"}` does **not** mean "the
root user". It means **the whole account**. roleC would delegate the decision to
Account A: *any* IAM user or role in Account A whose identity policies allow
`sts:AssumeRole` on roleC could assume it, and so could the root user.

| Trust policy principal | Who can assume roleC |
|---|---|
| `arn:aws:iam::000000000000:role/roleB` (**implemented**) | Only sessions of roleB. |
| `arn:aws:iam::000000000000:root` | roleB, **and** roleA (admin: `sts:AssumeRole` on `*`), **and** the Account A root user, **and** any role or user an Account A administrator creates or edits in the future. |

Concretely (from the local model's counterfactual): with root trust, roleA and the
Account A root user are ALLOWED into roleC. With the exact ARN they are DENIED.

- **Account B loses control.** Who reaches its bucket depends on IAM changes made
  in *another* account, which Account B can't review.
- **Blast radius.** Compromising *any* sufficiently privileged Account A principal
  (a leaked `ci` key with a broad policy, a misconfigured role) gives a path into
  Account B.
- **Least privilege.** The requirement is "only roleB", so the trust policy
  should say exactly that.

Caveat: an exact role ARN is resolved to the role's internal unique ID when the
policy is saved. If roleB is deleted and recreated, roleC's trust shows an ID
instead of the ARN and stops working until roleC is re-applied. That's a safety
feature: a new role with the same name doesn't inherit the trust.

## Task 4 - CI least-privilege policy

### What ci can do

A customer-managed policy `ci-least-privilege` (`account-a/ci-policy.tf`,
reference copy `policies/ci-policy.json`) is attached to the **ci user only**
(not group1, so `engine` does not inherit it):

| Capability | Actions | Resource |
|---|---|---|
| ECR login | `ecr:GetAuthorizationToken` | `*` (required, see below) |
| ECR push, one repository | `BatchCheckLayerAvailability`, `GetDownloadUrlForLayer`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage` | `arn:aws:ecr:<region>:<acct>:repository/<repo>` |
| New task definition revision | `ecs:RegisterTaskDefinition` | `*` (required, see below) |
| Deploy one service | `ecs:UpdateService`, `ecs:DescribeServices` | `arn:aws:ecs:<region>:<acct>:service/<cluster>/<service>` |
| Pass the task roles | `iam:PassRole` | exact execution-role and task-role ARNs, only when `iam:PassedToService = ecs-tasks.amazonaws.com` |
| Read artifacts | `s3:ListBucket` / `s3:GetObject` | `arn:aws:s3:::<bucket>` / `arn:aws:s3:::<bucket>/*` |

The target resources are **not** created by this repository. They are named by
variables, so the task stays a least-privilege *policy* exercise rather than an
application build.

### Wildcard resources: the documented exceptions

`Resource = "*"` is used only where the AWS authorization model requires it, such
as `ecr:GetAuthorizationToken` and `ecs:RegisterTaskDefinition`.
Resource-scopable deployment operations remain restricted to their exact
ECR/ECS/IAM/S3 ARNs.

- **`ecr:GetAuthorizationToken`** has no resource type. It returns a login token
  for the account's registry. The token alone grants nothing, because every image
  operation is still authorized separately against the repository ARN. So
  "login anywhere" does not mean "push anywhere" (test C).
- **`ecs:RegisterTaskDefinition`** *creates* a new `family:revision`. There is no
  existing ARN to scope to before the call, so it can't be restricted to a
  specific task-definition ARN. The dangerous part of a task definition, the
  roles it runs with, is still constrained, because registering a definition that
  references a role requires `iam:PassRole`, which is limited to the two exact
  role ARNs and to ECS tasks. (Optional further hardening: require request tags
  via `aws:RequestTag` conditions.)
- Each exception is in **its own statement with a single action**, so the `*`
  can't leak onto other actions. The POC verifies that no other statement uses
  `*`, a partial-wildcard ARN (other than `bucket/*`) or an action wildcard.

### Q7 - What permissions were deliberately excluded from CI?

| Excluded | Examples |
|---|---|
| Broad managed policies | `AdministratorAccess`, `PowerUserAccess`, `AmazonS3FullAccess`, `AmazonECS_FullAccess`, `AmazonEC2ContainerRegistryFullAccess`, `AmazonEC2ContainerRegistryPowerUser` |
| Action wildcards | `ecr:*`, `ecs:*`, `s3:*`, `iam:*` |
| ECR management and pull | `ecr:BatchDeleteImage`, `DeleteRepository`, `CreateRepository`, `SetRepositoryPolicy`, `DeleteRepositoryPolicy`, `PutLifecyclePolicy`, `PutImageTagMutability`, `BatchGetImage`, `DescribeImages` |
| ECS beyond one service update | `ecs:CreateService`, `DeleteService`, `CreateCluster`, `DeleteCluster`, `RunTask`, `StartTask`, `StopTask`, `DeregisterTaskDefinition`, `DescribeTaskDefinition`, `ExecuteCommand`, `UpdateService` on any other service |
| S3 writes | `s3:PutObject`, `DeleteObject`, `DeleteObjectVersion`, `PutObjectAcl`, `PutBucketPolicy`, `DeleteBucket`, and **any** access to other buckets |
| IAM | Everything except the scoped `iam:PassRole`: no `CreateUser`, `CreateRole`, `Attach*Policy`, `Put*Policy`, `CreateAccessKey`, `UpdateAssumeRolePolicy`; no `iam:PassRole` on other roles or to other services |
| Role assumption | `sts:AssumeRole` (ci cannot enter roleB/roleC or roleA) |
| Everything else | EC2, Lambda, CloudFormation, logs, secrets, KMS administration and so on |

### Q8 - Why were those permissions excluded?

- **Managed "FullAccess"/PowerUser policies** cover every resource of a service,
  or every service. A leaked CI credential (the most exposed credential in most
  organizations) would then be able to delete repositories, rewrite any bucket or
  stop every service. The assignment asks for one repository, one service and one
  bucket, and the policy says exactly that.
- **ECR delete/management:** the pipeline only *adds* images. Deleting images or
  repositories, or changing repository policies, could destroy rollback targets or
  open the repository to other accounts. Pull (`BatchGetImage`) is not needed,
  because the ECS **execution role** pulls the image at runtime, not CI.
  `GetDownloadUrlForLayer` is kept, read-only on the same repository, because
  docker/buildx reuse existing layers during push.
- **ECS create/delete/run:** CI deploys a new revision to an existing service.
  Creating services or running ad-hoc tasks would let a compromised pipeline run
  arbitrary containers, possibly with other roles. `DescribeTaskDefinition` is
  omitted because the pipeline registers a task definition kept in the repository.
  If it had to download the live definition first, that action (which also
  requires `*`) would be the one extra exception to add.
- **`iam:PassRole` scoped to two ARNs and `ecs-tasks.amazonaws.com`:** `PassRole`
  on `*` is a classic privilege escalation. CI could register a task definition,
  or create a Lambda function, that runs with an administrator role. The condition
  also stops the allowed roles from being handed to Lambda or EC2.
- **S3 write/delete:** artifacts are inputs to the deployment. Write access would
  let a compromised pipeline poison artifacts for later builds, and delete access
  would destroy them. `ListBucket` and `GetObject` cover "read artifacts".
- **Other IAM and `sts:AssumeRole`:** CI must not be able to change its own
  permissions, mint new credentials, or hop into other roles, including the
  cross-account path, which belongs to `engine`.
- **General principle:** every permission is a capability an attacker inherits if
  the CI credential leaks. The production recommendation (Q5) is to replace the
  `ci` IAM user with a **GitHub OIDC role** carrying this same policy, so there is
  no long-lived key to leak in the first place.

## Task 5 - Find and fix the bugs

The corrected policies are the Task 3 Terraform (`account-b/role-c.tf`), which is
the source of truth. The original, broken versions are kept only as test fixtures
(`tests/fixtures/task5/broken-*.json`) and are never referenced by deployable code.

### Q9 - Why was the original roleC trust policy broken?

```
BROKEN  "Principal": {"AWS": "arn:aws:iam::000000000000:user/roleB"}
FIXED   "Principal": {"AWS": "arn:aws:iam::000000000000:role/roleB"}
```

The trust policy is broken because `roleB` is an IAM **role**, but the Principal
ARN identifies `user/roleB`, an IAM **user**. The intended trusted principal is
`arn:aws:iam::000000000000:role/roleB`. The fixed policy trusts that exact role
rather than a user principal or the broader Account A root principal.

Why that makes the intended AssumeRole fail:

- When roleB calls `sts:AssumeRole`, the caller is a session of the role roleB.
  A trust policy entry for `...:user/roleB` names a different principal type and
  a different identity, so it does not authorize roleB. The trust side of the
  two-sided check (Task 3) is not satisfied, and the call is denied even though
  roleB's own identity policy allows it. The local model shows exactly this:
  `identity=Allow, trust=Deny`.
- Secondary detail (behavior can vary with principal existence and resolution):
  IAM validates principals when a trust policy is saved, so the broken policy may
  be rejected outright as an invalid principal. If a user named `roleB` did exist,
  the policy would instead trust that user, and roleB would still be locked out.
  Either way, it is the wrong principal ARN for the intended trust relationship.

### Q10 - Why was `Resource "*"` wrong for roleC S3 permissions?

```
BROKEN  "Action": "s3:*", "Resource": "*"
FIXED   "Action": "s3:*", "Resource": ["arn:aws:s3:::BUCKET", "arn:aws:s3:::BUCKET/*"]
```

The requirement is full access to **one named bucket**. `s3:*` on `"*"` grants
roleC S3 permissions across all resources rather than restricting access to the
intended bucket:

- every bucket and object in Account B (read, overwrite, delete, `DeleteBucket`);
- `PutBucketPolicy` / `PutPublicAccessBlock` on any of them, so roleC could expose
  or lock out other teams' data;
- account-level actions such as `ListAllMyBuckets` and `CreateBucket`;
- buckets in *other* accounts whose bucket policies trust Account B principals.

The local POC shows the broken policy allowing `ListBucket`, `GetObject`,
`DeleteBucket` and `PutBucketPolicy` on an unrelated bucket. The fixed and deployed
policies deny all of them while still allowing the target bucket and its objects.

**Why two ARNs, and why they are not interchangeable.** S3 actions apply to
different resource types:

- bucket-level actions (`s3:ListBucket`, `s3:GetBucketLocation`,
  `s3:GetBucketVersioning`, `s3:PutBucketPolicy`, `s3:DeleteBucket`) are
  authorized against `arn:aws:s3:::BUCKET`;
- object-level actions (`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`,
  `s3:GetObjectVersion`) are authorized against `arn:aws:s3:::BUCKET/*`.

`s3:*` on both ARNs grants each action on its **own** resource type. An
object action is never granted by the bucket ARN, and vice versa. Neither ARN alone
provides "full access to the bucket", and together they provide nothing beyond it.
