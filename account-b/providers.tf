provider "aws" {
  region = var.aws_region

  # Account B only. Prevents applying Account B resources into Account A.
  allowed_account_ids = [var.account_b_id]

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
      Stack       = "account-b"
    }
  }
}
