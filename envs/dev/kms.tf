# -----------------------------------------------------------------------------
# Encryption key (D-13)
#
# One customer-managed key for the data-lake buckets, so key access is auditable
# and revocable independently of bucket policy. Glue, Redshift and SageMaker
# roles will each need kms:Decrypt / kms:GenerateDataKey on this key — a missing
# grant surfaces as an opaque AccessDenied from S3, not from KMS.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "s3" {
  description             = "${local.name_prefix} data lake encryption (S3, Glue, Scheduler)"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true

  tags = {
    Name      = "${local.name_prefix}-s3"
    Component = "security"
  }
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${local.name_prefix}-s3"
  target_key_id = aws_kms_key.s3.key_id
}

# -----------------------------------------------------------------------------
# CloudWatch Logs key
#
# Separate from the S3 key because it needs a key policy naming the logs
# service, and CloudWatch will not write to a key it cannot use. The grant is
# scoped by encryption context to log groups in this account and region, so the
# service cannot be induced to decrypt anything else with it.
#
# If log groups stop receiving events after a change here, this policy is the
# first thing to check: CloudWatch fails closed and silently.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "logs_key" {
  # checkov:skip=CKV_AWS_109:KMS key policy. Resource "*" in a key policy means
  # "this key" — there is no other value it can take, so a wildcard here is not
  # the unscoped grant the check is looking for.
  # checkov:skip=CKV_AWS_111:Same. The root statement is mandatory: a key policy
  # without it is unmanageable and cannot even be deleted.
  # checkov:skip=CKV_AWS_356:Same. The service grant below is already scoped by
  # encryption context to log groups in this account and region.

  # Without this the key becomes unmanageable — including undeletable.
  statement {
    sid    = "AccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "${local.name_prefix} CloudWatch Logs encryption"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.logs_key.json

  tags = {
    Name      = "${local.name_prefix}-logs"
    Component = "security"
  }
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name_prefix}-logs"
  target_key_id = aws_kms_key.logs.key_id
}
