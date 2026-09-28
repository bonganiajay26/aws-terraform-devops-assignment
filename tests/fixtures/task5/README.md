# Task 5 fixtures - TEST DATA ONLY

| File | Content | Deployable? |
|---|---|---|
| `broken-trust-policy.json` | roleC trust with `arn:aws:iam::000000000000:user/roleB` (**BUG 1**, wrong principal type) | **No.** Never referenced by Terraform |
| `broken-s3-policy.json` | roleC permissions `s3:*` on `Resource "*"` (**BUG 2**, over-permission) | **No.** Never referenced by Terraform |
| `fixed-trust-policy.json` | roleC trust with `arn:aws:iam::000000000000:role/roleB` | Mirror of `account-b/role-c.tf` |
| `fixed-s3-policy.json` | `s3:*` on `arn:aws:s3:::<bucket>` and `arn:aws:s3:::<bucket>/*` | Mirror of `account-b/role-c.tf` |

The **source of truth** is the Terraform in `account-b/role-c.tf`. The `fixed-*`
files exist only for side-by-side comparison. `scripts/task5-local-poc.ps1`
asserts they are semantically identical to the policies Terraform renders, so
they can't drift. It also asserts that no `.tf` file references this folder or
contains either broken pattern.
