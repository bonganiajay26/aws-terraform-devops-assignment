variable "aws_region" {
  description = "AWS region for Account B resources."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region name, for example us-east-1."
  }
}

variable "account_b_id" {
  description = "12-digit AWS account ID of Account B (roleC and the cross-account S3 bucket)."
  type        = string
  default     = "111111111111"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_b_id))
    error_message = "account_b_id must be exactly 12 digits."
  }
}

variable "project_name" {
  description = "Project name used for tagging and resource naming."
  type        = string
  default     = "aws-terraform-devops-assignment"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.project_name))
    error_message = "project_name must be 3-40 characters of lowercase letters, digits and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment tag value."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "owner" {
  description = "Team or person responsible for these resources (Owner tag)."
  type        = string
  default     = "platform-team"

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

# ----------------------------- Task 3 - IAM -----------------------------

variable "account_a_id" {
  description = "12-digit AWS account ID of Account A. roleC trusts EXACTLY arn:aws:iam::<account_a_id>:role/roleB."
  type        = string
  default     = "000000000000"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_a_id))
    error_message = "account_a_id must be exactly 12 digits."
  }
}

variable "target_bucket_name" {
  description = "The ONE bucket roleC gets full access to. null = \"<project_name>-crossacct-<account_b_id>\"."
  type        = string
  default     = null

  validation {
    condition     = var.target_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.target_bucket_name))
    error_message = "target_bucket_name must be a valid S3 bucket name: 3-63 lowercase letters, digits, dots, hyphens."
  }
}

variable "create_control_bucket" {
  description = "Create a second, unrelated bucket used only by the negative test (roleC -> other bucket = AccessDenied)."
  type        = bool
  default     = true
}
