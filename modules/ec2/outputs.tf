output "instance_ids" {
  description = "Map of instance name => EC2 instance ID (all instances, protected or not)."
  value       = { for name, instance in local.all_instances : name => instance.id }
}

output "private_ips" {
  description = "Map of instance name => private IPv4 address."
  value       = { for name, instance in local.all_instances : name => instance.private_ip }
}

output "protected_instance_names" {
  description = "Names of instances guarded by lifecycle.prevent_destroy and API termination protection."
  value       = sort(keys(aws_instance.protected))
}

output "instance_summary" {
  description = "Per-instance configuration actually applied (used for POC verification)."
  value = {
    for name, instance in local.all_instances : name => {
      instance_type    = instance.instance_type
      key_name         = instance.key_name
      root_volume_type = instance.root_block_device[0].volume_type
      root_volume_size = instance.root_block_device[0].volume_size
      root_volume_iops = instance.root_block_device[0].iops
      protected        = contains(keys(aws_instance.protected), name)
    }
  }
}
