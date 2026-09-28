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
| 1 | Which EC2 instance is protected and why? | Task 1 |
| 2 | What happens with local state when multiple engineers operate on the same infrastructure? | Task 2 |
| 3 | How do S3 remote state and locking help? | Task 2 |
| 4 | Would engine/ci long-lived access keys be used in real production? | Task 3 |
| 5 | What should be used instead? | Task 3 |
| 6 | Why is trusting Account A root broader than trusting the roleB ARN? | Task 3 |
| 7 | What permissions were deliberately excluded from CI? | Task 4 |
| 8 | Why were those permissions excluded? | Task 4 |
| 9 | Why was the original roleC trust policy broken? | Task 5 |
| 10 | Why was `Resource "*"` wrong for roleC S3 permissions? | Task 5 |
