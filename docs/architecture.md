# Architecture

## Accounts

| Account | ID (placeholder) | Terraform root | Contents |
|---|---|---|---|
| A | `000000000000` | `account-a/` | EC2 fleet, group1 (engine, ci), group2 (developer1, developer2), roleA, roleB, ECR, ECS, artifact bucket access |
| A (state) | `000000000000` | `bootstrap/` | S3 state bucket, DynamoDB lock table |
| B | `111111111111` | `account-b/` | roleC, target S3 bucket |

Account IDs are variables (`account_a_id`, `account_b_id`, `state_account_id`). Each
provider sets `allowed_account_ids`, so a stack cannot be applied to the wrong account.

## Cross-account flow

```mermaid
sequenceDiagram
    participant P as Principal in Account A
    participant RB as roleB (Account A)
    participant STS as AWS STS
    participant RC as roleC (Account B)
    participant S3 as Target bucket (Account B)
    P->>STS: AssumeRole roleB
    STS-->>P: temporary credentials (roleB)
    P->>STS: AssumeRole arn:aws:iam::111111111111:role/roleC (as roleB)
    Note over STS: 1) roleB identity policy allows sts:AssumeRole on roleC<br/>2) roleC trust policy trusts role/roleB
    STS-->>P: temporary credentials (roleC)
    P->>S3: s3 actions on bucket and bucket/*
```

## State layout (Task 2)

```
s3://<state-bucket>/account-a/terraform.tfstate
s3://<state-bucket>/account-b/terraform.tfstate
bootstrap/  -> local state (it creates the backend itself)
```

## CI (safe mode)

```mermaid
flowchart LR
    PR[pull_request / push main] --> H[secret hygiene]
    PR --> F[terraform fmt -check]
    PR --> V[init -backend=false + validate<br/>bootstrap / account-a / account-b]
```

No AWS credentials. No plan. No apply.

## Naming and tagging

- Resources: `<project>-<purpose>`, lowercase with hyphens.
- Tags on every resource via `default_tags`: `Project`, `Environment`, `Owner`, `ManagedBy`, `Stack`.
