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

- It contains provider binaries (the AWS provider is several hundred MB) that are
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
| 4 | Would engine/ci long-lived access keys be used in real production? | Task 3 |
| 5 | What should be used instead? | Task 3 |
| 6 | Why is trusting Account A root broader than trusting the roleB ARN? | Task 3 |
| 7 | What permissions were deliberately excluded from CI? | Task 4 |
| 8 | Why were those permissions excluded? | Task 4 |
| 9 | Why was the original roleC trust policy broken? | Task 5 |
| 10 | Why was `Resource "*"` wrong for roleC S3 permissions? | Task 5 |

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
