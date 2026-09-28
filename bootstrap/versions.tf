terraform {
  # >= 1.5.0: no feature newer than 1.5 is used anywhere in this repo.
  # < 2.0.0 blocks untested major upgrades.
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # NOTE: bootstrap intentionally has NO backend block. It creates the
  # S3 bucket + DynamoDB table that the other stacks use as a backend,
  # so it must start with local state (see Task 2).
}
