# -----------------------------------------------------------------------------
# Task 3 - IAM users and groups (Account A)
#
#   group1 : engine, ci                 -> programmatic (CLI/API) only
#                                          NO login profile => no console sign-in
#   group2 : developer1, developer2     -> access model: console + CLI
#                                          permissions for self-service password,
#                                          access keys and MFA; roleA via MFA
#
# CREDENTIAL PROVISIONING IS INTENTIONALLY EXCLUDED FROM TERRAFORM STATE:
#   - no aws_iam_access_key resources (the secret would be stored in state)
#   - console login profiles only when console_pgp_key is set, so state and
#     outputs hold ONLY the PGP-encrypted password. Without a PGP key no login
#     profile is created; an administrator provisions console passwords out of
#     band (aws iam create-login-profile --password-reset-required).
# See NOTES.md Q4/Q5 for why long-lived keys should be avoided in production.
# -----------------------------------------------------------------------------

locals {
  account_a_iam_prefix = "arn:aws:iam::${var.account_a_id}"

  iam_users = merge(
    { for name in ["engine", "ci"] : name => { group = "group1", console = false } },
    { for name in var.console_user_names : name => { group = "group2", console = true } }
  )

  console_users = { for name, user in local.iam_users : name => user if user.console }

  # ARNs are built from variables (not resource attributes) so every policy
  # document is fully known at plan time and can be verified offline.
  user_arns = { for name in keys(local.iam_users) : name => "${local.account_a_iam_prefix}:user/${name}" }
}

resource "aws_iam_group" "group1" {
  name = "group1"
}

resource "aws_iam_group" "group2" {
  name = "group2"
}

resource "aws_iam_user" "this" {
  for_each = local.iam_users

  name = each.key

  # Lets `terraform destroy` remove users even if keys/MFA were added out of band.
  force_destroy = true

  tags = {
    Group      = each.value.group
    AccessType = each.value.console ? "console-and-cli" : "programmatic-only"
  }
}

# Exclusive membership: exactly these users, nothing else, in each group.
resource "aws_iam_group_membership" "group1" {
  name  = "group1-membership"
  group = aws_iam_group.group1.name
  users = [for name, user in local.iam_users : aws_iam_user.this[name].name if user.group == "group1"]
}

resource "aws_iam_group_membership" "group2" {
  name  = "group2-membership"
  group = aws_iam_group.group2.name
  users = [for name, user in local.iam_users : aws_iam_user.this[name].name if user.group == "group2"]
}

# Console login profiles: group2 ONLY, and ONLY when a PGP key is supplied.
# Without pgp_key the provider would store the generated password in PLAINTEXT
# in state, so no profile is created in that case (provisioned out of band).
# engine/ci never get a login profile.
resource "aws_iam_user_login_profile" "console" {
  for_each = var.console_pgp_key == null ? {} : local.console_users

  user                    = aws_iam_user.this[each.key].name
  password_reset_required = true

  # State/outputs hold only encrypted_password; decrypt offline with the private key.
  pgp_key = var.console_pgp_key

  lifecycle {
    ignore_changes = [password_reset_required, password_length, pgp_key]
  }
}

# ------------------------------- group2 policy -------------------------------

data "aws_iam_policy_document" "group2" {
  # GetAccountPasswordPolicy does not support resource-level permissions -> "*".
  statement {
    sid       = "ViewAccountPasswordPolicy"
    effect    = "Allow"
    actions   = ["iam:GetAccountPasswordPolicy"]
    resources = ["*"]
  }

  # CLI capability: each user manages ONLY their own password and access keys.
  statement {
    sid    = "ManageOwnPasswordAndAccessKeys"
    effect = "Allow"
    actions = [
      "iam:ChangePassword",
      "iam:GetUser",
      "iam:GetLoginProfile",
      "iam:CreateAccessKey",
      "iam:DeleteAccessKey",
      "iam:ListAccessKeys",
      "iam:UpdateAccessKey",
      "iam:GetAccessKeyLastUsed",
    ]
    resources = ["${local.account_a_iam_prefix}:user/$${aws:username}"]
  }

  statement {
    sid    = "ManageOwnVirtualMfaDevice"
    effect = "Allow"
    actions = [
      "iam:CreateVirtualMFADevice",
      "iam:DeleteVirtualMFADevice",
    ]
    resources = ["${local.account_a_iam_prefix}:mfa/$${aws:username}"]
  }

  statement {
    sid    = "ManageOwnMfa"
    effect = "Allow"
    actions = [
      "iam:EnableMFADevice",
      "iam:ListMFADevices",
      "iam:ResyncMFADevice",
      "iam:DeactivateMFADevice",
    ]
    resources = ["${local.account_a_iam_prefix}:user/$${aws:username}"]
  }

  # Real work happens through roleA, and only with MFA.
  statement {
    sid       = "AssumeRoleAWithMfa"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [local.role_a_arn]

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_group_policy" "group2" {
  name   = "group2-self-service-and-assume-roleA"
  group  = aws_iam_group.group2.name
  policy = data.aws_iam_policy_document.group2.json
}

# -------------------------------- engine policy ------------------------------
# Only engine (not ci) may enter the cross-account path via roleB.

data "aws_iam_policy_document" "engine" {
  statement {
    sid       = "AssumeRoleBOnly"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [local.role_b_arn]
  }
}

resource "aws_iam_user_policy" "engine" {
  name   = "engine-assume-roleB"
  user   = aws_iam_user.this["engine"].name
  policy = data.aws_iam_policy_document.engine.json
}
