# ----------------------------- Task 3 - IAM -----------------------------

output "role_c_arn" {
  description = "roleC ARN - roleB assumes this (aws sts assume-role --role-arn ...)."
  value       = aws_iam_role.role_c.arn
}

output "role_c_trusted_principal" {
  description = "The ONLY principal roleC trusts."
  value       = local.role_b_arn
}

output "target_bucket_name" {
  description = "The one bucket roleC can fully access."
  value       = aws_s3_bucket.target.id
}

output "target_bucket_arn" {
  description = "ARN of the target bucket."
  value       = aws_s3_bucket.target.arn
}

output "control_bucket_name" {
  description = "Unrelated bucket for the negative test (roleC must be denied). null when disabled."
  value       = try(aws_s3_bucket.control[0].id, null)
}
