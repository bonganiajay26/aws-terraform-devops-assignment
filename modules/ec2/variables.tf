variable "ami_id" {
  description = "AMI ID used for every instance. AMIs are region-specific; pass one that exists in the provider region (see README Task 1 for how to look one up)."
  type        = string

  validation {
    condition     = can(regex("^ami-([0-9a-f]{8}|[0-9a-f]{17})$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxx or ami-xxxxxxxxxxxxxxxxx (lowercase hex)."
  }
}

variable "instances" {
  description = <<-EOT
    ONE map that drives ALL instances (for_each). Key = instance name (also the Name tag).
      instance_type          - EC2 instance type, e.g. t3.micro
      root_volume_type       - gp2 | gp3 | io1 | io2 (st1/sc1 cannot be boot volumes)
      root_volume_size       - GiB
      root_volume_iops       - required for io1/io2, optional for gp3, not allowed for gp2
      root_volume_throughput - MiB/s, gp3 only
      key_name               - name of an EXISTING EC2 key pair in the region
      protected              - true => lifecycle.prevent_destroy + API termination protection
      environment / owner    - optional per-instance overrides of the module-level tags
      tags                   - optional extra tags
  EOT

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

  validation {
    condition     = length(var.instances) > 0
    error_message = "instances must contain at least one instance definition."
  }

  validation {
    condition     = alltrue([for name, cfg in var.instances : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", name))])
    error_message = "Instance names (map keys) must be lowercase letters, digits and hyphens, max 63 characters."
  }

  validation {
    condition     = alltrue([for name, cfg in var.instances : can(regex("^[a-z0-9-]+\\.[a-z0-9]+$", cfg.instance_type))])
    error_message = "instance_type must look like family.size, for example t3.micro."
  }

  validation {
    condition     = alltrue([for name, cfg in var.instances : length(trimspace(cfg.key_name)) > 0])
    error_message = "key_name must not be empty; every instance needs its own existing EC2 key pair."
  }

  # st1/sc1 (HDD) cannot be boot volumes; "standard" (magnetic) is previous generation.
  validation {
    condition     = alltrue([for name, cfg in var.instances : contains(["gp2", "gp3", "io1", "io2"], cfg.root_volume_type)])
    error_message = "root_volume_type must be one of gp2, gp3, io1, io2. st1/sc1 cannot be root (boot) volumes and standard is previous generation."
  }

  # Size limits per volume type (GiB): gp2/gp3 1-16384, io1 4-16384, io2 4-65536.
  validation {
    condition = alltrue([
      for name, cfg in var.instances : try(
        cfg.root_volume_type == "io2" ? (cfg.root_volume_size >= 4 && cfg.root_volume_size <= 65536) :
        cfg.root_volume_type == "io1" ? (cfg.root_volume_size >= 4 && cfg.root_volume_size <= 16384) :
        (cfg.root_volume_size >= 1 && cfg.root_volume_size <= 16384),
        false
      )
    ])
    error_message = "root_volume_size out of range: gp2/gp3 1-16384 GiB, io1 4-16384 GiB, io2 4-65536 GiB."
  }

  # IOPS presence rules.
  validation {
    condition = alltrue([
      for name, cfg in var.instances : (
        contains(["io1", "io2"], cfg.root_volume_type) ? cfg.root_volume_iops != null :
        cfg.root_volume_type == "gp2" ? cfg.root_volume_iops == null :
        true
      )
    ])
    error_message = "root_volume_iops is required for io1/io2 and must not be set for gp2 (gp2 IOPS are derived from size)."
  }

  # IOPS ranges and IOPS:GiB ratios.
  #   io1: 100-64000, max 50 IOPS per GiB
  #   io2: 100-256000, max 1000 IOPS per GiB
  #   gp3: 3000-16000, max 500 IOPS per GiB above the 3000 baseline
  # (Conservative published limits - re-check AWS docs if AWS raises them.)
  validation {
    condition = alltrue([
      for name, cfg in var.instances : cfg.root_volume_iops == null ? true : try(
        cfg.root_volume_type == "io1" ? (cfg.root_volume_iops >= 100 && cfg.root_volume_iops <= min(64000, 50 * cfg.root_volume_size)) :
        cfg.root_volume_type == "io2" ? (cfg.root_volume_iops >= 100 && cfg.root_volume_iops <= min(256000, 1000 * cfg.root_volume_size)) :
        cfg.root_volume_type == "gp3" ? (cfg.root_volume_iops >= 3000 && cfg.root_volume_iops <= min(16000, max(3000, 500 * cfg.root_volume_size))) :
        false,
        false
      )
    ])
    error_message = "root_volume_iops out of range: io1 100-64000 (max 50/GiB), io2 100-256000 (max 1000/GiB), gp3 3000-16000 (max 500/GiB)."
  }

  # Throughput: gp3 only, 125-1000 MiB/s and at most 0.25 MiB/s per provisioned IOPS.
  validation {
    condition = alltrue([
      for name, cfg in var.instances : cfg.root_volume_throughput == null ? true : try(
        cfg.root_volume_type == "gp3" &&
        cfg.root_volume_throughput >= 125 &&
        cfg.root_volume_throughput <= min(1000, coalesce(cfg.root_volume_iops, 3000) / 4),
        false
      )
    ])
    error_message = "root_volume_throughput is only valid for gp3: 125-1000 MiB/s and at most IOPS/4."
  }

  validation {
    condition = alltrue([
      for name, cfg in var.instances : cfg.environment == null ? true : contains(["dev", "staging", "prod"], cfg.environment)
    ])
    error_message = "Per-instance environment override must be one of: dev, staging, prod."
  }
}

variable "environment" {
  description = "Default Environment tag for every instance (can be overridden per instance)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "owner" {
  description = "Default Owner tag for every instance (can be overridden per instance)."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "subnet_id" {
  description = "Subnet for the instances. null = default subnet of the default VPC in the provider region."
  type        = string
  default     = null
}

variable "vpc_security_group_ids" {
  description = "Security groups for the instances. Empty list = the VPC default security group."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Extra tags applied to every instance and its root volume."
  type        = map(string)
  default     = {}
}
