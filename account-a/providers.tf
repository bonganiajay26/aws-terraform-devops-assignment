provider "aws" {
  region = var.aws_region

  # Account A only. Prevents applying Account A resources into Account B.
  allowed_account_ids = [var.account_a_id]

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
      Stack       = "account-a"
    }
  }
}
