# -----------------------------------------------------------------------------
# Task 2 - Remote state (S3 + DynamoDB locking)
#
# Backend blocks cannot use variables, so this is a PARTIAL configuration:
#   - fixed here   : the state key (unique per stack) and encryption
#   - backend.hcl  : bucket, region, lock table, profile (environment-specific,
#                    git-ignored; copy from backend.hcl.example)
#
#   terraform init -backend-config=backend.hcl                  # first time
#   terraform init -backend-config=backend.hcl -migrate-state   # local -> S3
#
# Local validation / CI use `terraform init -backend=false` and never touch S3.
# -----------------------------------------------------------------------------
terraform {
  backend "s3" {
    key     = "account-a/terraform.tfstate"
    encrypt = true
  }
}
