variable "aws_region" {
  description = "AWS region for Account A resources."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region name, for example us-east-1."
  }
}

variable "account_a_id" {
  description = "12-digit AWS account ID of Account A (EC2, IAM users/groups, roleA, roleB, ECR, ECS)."
  type        = string
  default     = "000000000000"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_a_id))
    error_message = "account_a_id must be exactly 12 digits."
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
