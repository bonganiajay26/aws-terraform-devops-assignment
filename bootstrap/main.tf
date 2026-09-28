# -----------------------------------------------------------------------------
# Task 2 - Terraform state backend bootstrap
#
# Chicken-and-egg: a stack cannot use an S3 backend that does not exist yet.
# This stack therefore runs ONCE with LOCAL state and creates:
#   - S3 bucket   : versioned, encrypted, public access blocked, TLS-only
#   - DynamoDB    : LockID table used by the S3 backend for state locking
# account-a/ and account-b/ then point their backend "s3" at these resources.
#
# Both resources carry prevent_destroy (Terraform-side) plus AWS-side guards
# (force_destroy = false, DynamoDB deletion protection): losing the bucket
# means losing every stack's state.
# -----------------------------------------------------------------------------

locals {
  state_bucket_name = coalesce(var.state_bucket_name, "${var.project_name}-tfstate-${var.state_account_id}")
  lock_table_name   = coalesce(var.lock_table_name, "${var.project_name}-tf-locks")
  use_kms           = var.kms_key_arn != null
}

# ------------------------------- S3 bucket -----------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # Never delete a bucket that still contains state versions.
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

# ACLs disabled - access is controlled only by IAM and the bucket policy.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every state write creates a new object version -> any earlier state can be restored.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.use_kms ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = local.use_kms
  }
}

# Keep old state versions for recovery, but not forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_version_retention_days
      newer_noncurrent_versions = 10
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# Reject any request that is not made over TLS.
data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  # Public access block must exist first so the policy is evaluated under it.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ----------------------------- DynamoDB lock table ---------------------------

# The S3 backend writes an item with LockID = "<bucket>/<key>" while an
# operation holds the lock (plus "<bucket>/<key>-md5" digest items).
resource "aws_dynamodb_table" "locks" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  deletion_protection_enabled = true

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}
