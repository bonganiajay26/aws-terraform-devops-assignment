provider "aws" {
  region = var.aws_region

  # Safety guard: Terraform refuses to run if the credentials in use
  # belong to any other account.
  allowed_account_ids = [var.state_account_id]

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
      Stack       = "bootstrap"
    }
  }
}
