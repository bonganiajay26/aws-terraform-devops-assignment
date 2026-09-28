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
| 2 | What happens with local state when multiple engineers operate on the same infrastructure? | Task 2 |
| 3 | How do S3 remote state and locking help? | Task 2 |
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
