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

# ----------------------------- Task 1 - EC2 -----------------------------

variable "ami_id" {
  description = "AMI ID for all instances. Region-specific - no default on purpose. Must be x86_64 because all instance types are t3."
  type        = string
}

variable "instances" {
  description = "ONE map driving all EC2 instances (for_each). Field rules are validated in modules/ec2/variables.tf."
  type = map(object({
    instance_type          = string
    root_volume_type       = string
    root_volume_size       = number
    root_volume_iops       = optional(number)
    root_volume_throughput = optional(number)
    key_name               = string
    protected              = optional(bool, false)
    environment            = optional(string)
    owner                  = optional(string)
    tags                   = optional(map(string), {})
  }))

  # Assignment requirement: at least one critical instance must be protected.
  validation {
    condition     = length([for name, cfg in var.instances : name if cfg.protected]) >= 1
    error_message = "At least one instance must set protected = true (assignment: protect the critical instance)."
  }
}

variable "subnet_id" {
  description = "Subnet for the instances. null = default subnet of the default VPC."
  type        = string
  default     = null
}

variable "vpc_security_group_ids" {
  description = "Security group IDs for the instances. Empty = VPC default security group."
  type        = list(string)
  default     = []
}

# ----------------------------- Task 3 - IAM -----------------------------

variable "account_b_id" {
  description = "12-digit AWS account ID of Account B (hosts roleC). Used to build the exact roleC ARN for roleB."
  type        = string
  default     = "111111111111"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_b_id))
    error_message = "account_b_id must be exactly 12 digits."
  }
}

variable "console_user_names" {
  description = "The two group2 users that get console + CLI access."
  type        = list(string)
  default     = ["developer1", "developer2"]

  validation {
    condition     = length(var.console_user_names) == 2 && length(distinct(var.console_user_names)) == 2
    error_message = "console_user_names must contain exactly two distinct names (assignment: two console users)."
  }

  validation {
    condition     = alltrue([for name in var.console_user_names : can(regex("^[a-zA-Z0-9+=,.@_-]{1,64}$", name))])
    error_message = "Each console user name must be a valid IAM user name (1-64 chars of letters, digits, +=,.@_-)."
  }

  validation {
    condition     = length(setintersection(toset(var.console_user_names), toset(["engine", "ci"]))) == 0
    error_message = "engine and ci are programmatic-only (group1) and cannot be console users."
  }
}

variable "console_pgp_key" {
  description = "PGP public key (base64) or keybase:<user>. When set, Terraform creates group2 console login profiles and stores ONLY the PGP-encrypted initial password. null (default) = no login profiles in Terraform (no password ever in state); provision console passwords out of band."
  type        = string
  default     = null

  validation {
    condition     = var.console_pgp_key == null || length(trimspace(coalesce(var.console_pgp_key, " "))) > 0
    error_message = "console_pgp_key must be null or a non-empty PGP key / keybase:<user> reference."
  }
}
