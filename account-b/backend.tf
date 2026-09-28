# -----------------------------------------------------------------------------
# Task 2 - Remote state (S3 + DynamoDB locking)
#
# Same bucket and lock table as account-a, DIFFERENT key -> separate state files,
# separate locks. The state bucket lives in Account A, so backend.hcl uses an
# Account A profile for the BACKEND while the provider uses Account B credentials.
#
#   terraform init -backend-config=backend.hcl
#   terraform init -backend-config=backend.hcl -migrate-state   # local -> S3
# -----------------------------------------------------------------------------
terraform {
  backend "s3" {
    key     = "account-b/terraform.tfstate"
    encrypt = true
  }
}
