# -----------------------------------------------------------------------------
# Multi-instance EC2 module
#
# ONE input map (var.instances) drives EVERY instance through for_each.
#
# Why two resource blocks instead of one?
#   lifecycle arguments must be literal values: Terraform processes the
#   lifecycle block before for_each/each exist, so
#       prevent_destroy = each.value.protected
#   is rejected at init/validate time. The single input map is therefore
#   split into two filtered views of the SAME data:
#     aws_instance.standard  <- instances with protected = false
#     aws_instance.protected <- instances with protected = true (prevent_destroy)
#   Adding, removing or reconfiguring instances is still a data-only change
#   in var.instances. The two blocks are identical except for
#   disable_api_termination and the lifecycle block - keep them in sync.
# -----------------------------------------------------------------------------

locals {
  standard_instances  = { for name, cfg in var.instances : name => cfg if !cfg.protected }
  protected_instances = { for name, cfg in var.instances : name => cfg if cfg.protected }

  # Name / Environment / Owner are always set and win over any extra tags.
  instance_tags = {
    for name, cfg in var.instances : name => merge(
      var.tags,
      cfg.tags,
      {
        Name        = name
        Environment = coalesce(cfg.environment, var.environment)
        Owner       = coalesce(cfg.owner, var.owner)
      }
    )
  }

  # null lets AWS attach the VPC default security group.
  security_group_ids = length(var.vpc_security_group_ids) > 0 ? var.vpc_security_group_ids : null

  # Single view over both groups for outputs.
  all_instances = merge(aws_instance.standard, aws_instance.protected)
}

resource "aws_instance" "standard" {
  for_each = local.standard_instances

  ami                     = var.ami_id
  instance_type           = each.value.instance_type
  key_name                = each.value.key_name
  subnet_id               = var.subnet_id
  vpc_security_group_ids  = local.security_group_ids
  disable_api_termination = false

  # IMDSv2 only - blocks SSRF-style credential theft via IMDSv1.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = each.value.root_volume_type
    volume_size           = each.value.root_volume_size
    iops                  = each.value.root_volume_iops
    throughput            = each.value.root_volume_throughput
    encrypted             = true
    delete_on_termination = true
    tags                  = local.instance_tags[each.key]
  }

  tags = local.instance_tags[each.key]
}

resource "aws_instance" "protected" {
  for_each = local.protected_instances

  ami                    = var.ami_id
  instance_type          = each.value.instance_type
  key_name               = each.value.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = local.security_group_ids

  # Defence in depth: AWS-side termination protection also blocks
  # console / CLI / API terminations that bypass Terraform.
  disable_api_termination = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = each.value.root_volume_type
    volume_size           = each.value.root_volume_size
    iops                  = each.value.root_volume_iops
    throughput            = each.value.root_volume_throughput
    encrypted             = true
    delete_on_termination = true
    tags                  = local.instance_tags[each.key]
  }

  tags = local.instance_tags[each.key]

  # Terraform-side guard: any plan that would destroy (or replace) an
  # instance in this block fails with "Instance cannot be destroyed".
  lifecycle {
    prevent_destroy = true
  }
}
