# -----------------------------------------------------------------------------
# LOCAL MECHANISM DEMO - NOT AWS EVIDENCE
#
# Mirrors the split pattern of modules/ec2 using terraform_data (built into
# Terraform, no provider, no cloud). Proves locally that:
#   1. one input map + two filtered for_each views is valid Terraform
#   2. removing an UNPROTECTED key plans a normal destroy
#   3. removing the PROTECTED key fails with "Instance cannot be destroyed"
#   4. `terraform destroy` fails for the protected key
# Run by scripts/task1-local-poc.ps1 in a TEMP copy (state never lands in Git).
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0, < 2.0.0"
}

variable "instances" {
  type = map(object({
    protected = optional(bool, false)
  }))

  default = {
    web01 = {}
    web02 = {}
    web03 = { protected = true }
    web04 = {}
    web05 = {}
  }
}

locals {
  standard_instances  = { for name, cfg in var.instances : name => cfg if !cfg.protected }
  protected_instances = { for name, cfg in var.instances : name => cfg if cfg.protected }
}

resource "terraform_data" "standard" {
  for_each = local.standard_instances

  input = each.key
}

resource "terraform_data" "protected" {
  for_each = local.protected_instances

  input = each.key

  lifecycle {
    prevent_destroy = true
  }
}

output "standard" {
  value = sort(keys(terraform_data.standard))
}

output "protected" {
  value = sort(keys(terraform_data.protected))
}
