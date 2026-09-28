# ----------------------------- Task 1 - EC2 -----------------------------

output "instance_ids" {
  description = "Map of instance name => EC2 instance ID."
  value       = module.ec2.instance_ids
}

output "private_ips" {
  description = "Map of instance name => private IPv4 address."
  value       = module.ec2.private_ips
}

output "protected_instance_names" {
  description = "Instances protected by prevent_destroy and API termination protection."
  value       = module.ec2.protected_instance_names
}

output "instance_summary" {
  description = "Per-instance type / key pair / root volume configuration."
  value       = module.ec2.instance_summary
}
