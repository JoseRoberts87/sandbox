# -----------------------------------------------------------------------------
# Encryption key (D-13)
#
# One customer-managed key for the data-lake buckets, so key access is auditable
# and revocable independently of bucket policy. Glue, Redshift and SageMaker
# roles will each need kms:Decrypt / kms:GenerateDataKey on this key — a missing
# grant surfaces as an opaque AccessDenied from S3, not from KMS.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "s3" {
  description             = "${local.name_prefix} data lake S3 encryption"
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
