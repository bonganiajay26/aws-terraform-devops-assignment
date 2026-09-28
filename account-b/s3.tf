# -----------------------------------------------------------------------------
# Task 3 - Account B buckets
#
#   target  : the ONE bucket roleC may fully access
#   control : an unrelated bucket (test-only) proving roleC is DENIED elsewhere
# -----------------------------------------------------------------------------

locals {
  target_bucket_name  = coalesce(var.target_bucket_name, "${var.project_name}-crossacct-${var.account_b_id}")
  target_bucket_arn   = "arn:aws:s3:::${local.target_bucket_name}"
  control_bucket_name = "${var.project_name}-control-${var.account_b_id}"
}

resource "aws_s3_bucket" "target" {
  bucket = local.target_bucket_name
}

resource "aws_s3_bucket_ownership_controls" "target" {
  bucket = aws_s3_bucket.target.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "target" {
  bucket = aws_s3_bucket.target.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "target" {
  bucket = aws_s3_bucket.target.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "target" {
  bucket = aws_s3_bucket.target.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "target_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      local.target_bucket_arn,
      "${local.target_bucket_arn}/*",
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

resource "aws_s3_bucket_policy" "target" {
  bucket = aws_s3_bucket.target.id
  policy = data.aws_iam_policy_document.target_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.target]
}

# ------------------------- control bucket (test only) ------------------------

resource "aws_s3_bucket" "control" {
  count = var.create_control_bucket ? 1 : 0

  bucket = local.control_bucket_name

  # Test fixture only - allow cleanup even if test objects remain.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "control" {
  count = var.create_control_bucket ? 1 : 0

  bucket = aws_s3_bucket.control[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
