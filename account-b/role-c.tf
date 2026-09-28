# -----------------------------------------------------------------------------
# Task 3 - roleC (Account B)
#
# TRUST: exactly one principal
#     arn:aws:iam::<account_a_id>:role/roleB
#   NOT arn:aws:iam::<account_a_id>:root       (would delegate to EVERY principal
#                                               in Account A that has sts:AssumeRole)
#   NOT arn:aws:iam::<account_a_id>:user/roleB (roleB is a ROLE, not a user)
#
# PERMISSIONS: full S3 access to ONE bucket only
#   arn:aws:s3:::<bucket>     bucket-level operations (ListBucket, GetBucketLocation,
#                             PutBucketPolicy, DeleteBucket, ...)
#   arn:aws:s3:::<bucket>/*   object-level operations (GetObject, PutObject,
#                             DeleteObject, ...)
#   Never Resource "*" - that would cover every bucket roleC's account can reach.
#
# Apply order: account-a FIRST. IAM validates trust principals at creation time,
# so roleC cannot be created until roleB exists ("Invalid principal in policy").
# -----------------------------------------------------------------------------

locals {
  role_b_arn = "arn:aws:iam::${var.account_a_id}:role/roleB"
}

data "aws_iam_policy_document" "role_c_trust" {
  statement {
    sid     = "TrustRoleBFromAccountAOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.role_b_arn]
    }
  }
}

resource "aws_iam_role" "role_c" {
  name                 = "roleC"
  description          = "Assumable only by Account A roleB; full access to one S3 bucket (Task 3)."
  assume_role_policy   = data.aws_iam_policy_document.role_c_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "role_c" {
  statement {
    sid     = "FullAccessToTargetBucketOnly"
    effect  = "Allow"
    actions = ["s3:*"]

    resources = [
      local.target_bucket_arn,
      "${local.target_bucket_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "role_c" {
  name   = "roleC-target-bucket-full-access"
  role   = aws_iam_role.role_c.id
  policy = data.aws_iam_policy_document.role_c.json
}
