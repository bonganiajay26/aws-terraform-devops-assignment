variable "aws_region" {
  description = "AWS region that hosts the Terraform state bucket and lock table."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region name, for example us-east-1."
  }
}

variable "state_account_id" {
  description = "12-digit ID of the AWS account that owns the Terraform state (Account A in this assignment)."
  type        = string
  default     = "000000000000"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.state_account_id))
    error_message = "state_account_id must be exactly 12 digits."
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

# ------------------------ Task 2 - remote state -------------------------

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state. null = \"<project_name>-tfstate-<state_account_id>\"."
  type        = string
  default     = null

  validation {
    condition     = var.state_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name: 3-63 lowercase letters, digits, dots, hyphens."
  }
}

variable "lock_table_name" {
  description = "DynamoDB table used for state locking. null = \"<project_name>-tf-locks\"."
  type        = string
  default     = null

  validation {
    condition     = var.lock_table_name == null || can(regex("^[a-zA-Z0-9_.-]{3,255}$", var.lock_table_name))
    error_message = "lock_table_name must be 3-255 characters: letters, digits, underscore, dot, hyphen."
  }
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for state encryption. null = SSE-S3 (AES256)."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>) or null."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days before an OLD (non-current) state version expires. The newest 10 old versions are always kept."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 1
    error_message = "noncurrent_version_retention_days must be at least 1."
  }
}
