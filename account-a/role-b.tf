# -----------------------------------------------------------------------------
# Task 3 - roleB: its ONLY permission is sts:AssumeRole on roleC in Account B
#
#   Allow sts:AssumeRole  on  arn:aws:iam::<account_b_id>:role/roleC
#
# No EC2, S3, IAM, ECR, ECS or any other permission; no managed policies attached.
# Cross-account AssumeRole is two-sided: this identity policy (Account A side)
# AND roleC's trust policy (Account B side, account-b/role-c.tf) must both allow it.
# -----------------------------------------------------------------------------

locals {
  role_b_arn = "${local.account_a_iam_prefix}:role/roleB"
  role_c_arn = "arn:aws:iam::${var.account_b_id}:role/roleC"
}

# Trust: only the engine user may assume roleB.
data "aws_iam_policy_document" "role_b_trust" {
  statement {
    sid     = "TrustEngineUserOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.user_arns["engine"]]
    }
  }
}

resource "aws_iam_role" "role_b" {
  name                 = "roleB"
  description          = "Cross-account hop: may only assume roleC in Account B (Task 3)."
  assume_role_policy   = data.aws_iam_policy_document.role_b_trust.json
  max_session_duration = 3600

  depends_on = [aws_iam_user.this]
}

data "aws_iam_policy_document" "role_b" {
  statement {
    sid       = "AssumeRoleCOnly"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [local.role_c_arn]
  }
}

resource "aws_iam_role_policy" "role_b" {
  name   = "roleB-assume-roleC-only"
  role   = aws_iam_role.role_b.id
  policy = data.aws_iam_policy_document.role_b.json
}
