output "state_bucket_name" {
  description = "S3 bucket that stores Terraform state for account-a and account-b."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "DynamoDB table used for state locking."
  value       = aws_dynamodb_table.locks.name
}

output "lock_table_arn" {
  description = "ARN of the lock table."
  value       = aws_dynamodb_table.locks.arn
}

output "backend_hcl" {
  description = "Paste into account-a/backend.hcl and account-b/backend.hcl (both stacks share bucket + table, keys differ in backend.tf)."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.state.id}"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.locks.name}"
    profile        = "account-a"
  EOT
}
