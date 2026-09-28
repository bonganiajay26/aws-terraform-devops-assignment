# -----------------------------------------------------------------------------
# Task 3 - roleA: administrative access to every AWS service EXCEPT IAM
#
# NOT AdministratorAccess. A customer-managed policy with two statements:
#   1. Allow  NotAction iam:*  Resource *  -> every action of every service but IAM
#   2. Deny   Action    iam:*  Resource *  -> explicit deny
#
# Why both? Statement 1 alone grants nothing in IAM, but if another policy that
# allows IAM is ever attached to roleA, that allow would win. An explicit Deny
# always overrides any Allow (identity, resource or session policy), so IAM stays
# blocked no matter what else is attached.
#
# Resource "*" is technically justified: this IS the administrator role.
# -----------------------------------------------------------------------------

locals {
  role_a_arn = "${local.account_a_iam_prefix}:role/roleA"
}

# Trust: only the named console users, only with MFA.
data "aws_iam_policy_document" "role_a_trust" {
  statement {
    sid     = "TrustGroup2UsersWithMfa"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [for name in var.console_user_names : local.user_arns[name]]
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "role_a" {
  name                 = "roleA"
  description          = "Administrative access to all AWS services except IAM (Task 3)."
  assume_role_policy   = data.aws_iam_policy_document.role_a_trust.json
  max_session_duration = 3600

  # IAM rejects trust policies that name principals which do not exist yet.
  depends_on = [aws_iam_user.this]
}

data "aws_iam_policy_document" "role_a_admin_except_iam" {
  statement {
    sid         = "AllowAllServicesExceptIam"
    effect      = "Allow"
    not_actions = ["iam:*"]
    resources   = ["*"]
  }

  statement {
    sid       = "DenyAllIam"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "role_a_admin_except_iam" {
  name        = "roleA-admin-except-iam"
  description = "Allow all actions except IAM; explicitly deny IAM."
  policy      = data.aws_iam_policy_document.role_a_admin_except_iam.json
}

resource "aws_iam_role_policy_attachment" "role_a_admin_except_iam" {
  role       = aws_iam_role.role_a.name
  policy_arn = aws_iam_policy.role_a_admin_except_iam.arn
}
