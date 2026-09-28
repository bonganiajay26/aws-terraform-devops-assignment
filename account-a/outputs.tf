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

# ----------------------------- Task 3 - IAM -----------------------------
# No access key IDs or secrets are output (none are created by Terraform).

output "iam_group_members" {
  description = "Members of group1 (programmatic only) and group2 (console + CLI)."
  value = {
    group1 = sort(aws_iam_group_membership.group1.users)
    group2 = sort(aws_iam_group_membership.group2.users)
  }
}

output "iam_user_arns" {
  description = "ARNs of all IAM users."
  value       = { for name, user in aws_iam_user.this : name => user.arn }
}

output "console_user_names" {
  description = "group2 users intended for console + CLI access."
  value       = sort(var.console_user_names)
}

output "console_login_profiles_managed_by_terraform" {
  description = "Users whose console login profile Terraform manages (empty unless console_pgp_key is set)."
  value       = sort(keys(aws_iam_user_login_profile.console))
}

output "console_encrypted_passwords" {
  description = "PGP-ENCRYPTED initial console passwords (only when console_pgp_key is set; decrypt offline). Never plaintext."
  value       = { for name, profile in aws_iam_user_login_profile.console : name => profile.encrypted_password }
}

output "role_a_arn" {
  description = "roleA - admin except IAM."
  value       = aws_iam_role.role_a.arn
}

output "role_b_arn" {
  description = "roleB - may only assume roleC. Must equal the principal trusted by roleC in Account B."
  value       = aws_iam_role.role_b.arn
}

# ----------------------------- Task 4 - CI -----------------------------

output "ci_policy_arn" {
  description = "Customer-managed least-privilege policy attached to the ci user."
  value       = aws_iam_policy.ci.arn
}

output "ci_policy_targets" {
  description = "Exact resources the ci policy is scoped to."
  value = {
    ecr_repository      = local.ci_ecr_repository_arn
    ecs_service         = local.ci_ecs_service_arn
    ecs_execution_role  = local.ci_execution_role_arn
    ecs_task_role       = local.ci_task_role_arn
    artifact_bucket     = local.ci_artifact_bucket
    artifact_objects    = "${local.ci_artifact_bucket}/*"
    wildcard_exceptions = ["ecr:GetAuthorizationToken", "ecs:RegisterTaskDefinition"]
  }
}
