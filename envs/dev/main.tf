data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # S3 bucket names are globally unique across all of AWS. The account ID is a
  # deterministic suffix that avoids collisions without a random value in state.
  bucket_suffix = "${var.owner}"
}

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

# -----------------------------------------------------------------------------
# Raw zone (D-02, D-11, D-12, D-14)
#
# Data lands here exactly as received and is never modified in place. Everything
# downstream is regenerable from this bucket, which is why versioning is on and
# nothing expires.
#
# Expected layout (D-12):
#   s3://<bucket>/<source>/<dataset>/ingest_date=YYYY-MM-DD/<file>
# -----------------------------------------------------------------------------

module "raw" {
  source = "../../modules/s3_bucket"

  bucket_name = "${local.name_prefix}-raw-${local.bucket_suffix}"
  kms_key_arn = aws_kms_key.s3.arn

  versioning_enabled                 = true
  transition_days                    = var.raw_transition_days
  transition_storage_class           = "GLACIER_IR"
  noncurrent_version_expiration_days = var.raw_noncurrent_version_expiration_days
  force_destroy                      = var.force_destroy_buckets

  tags = {
    Name      = "${local.name_prefix}-raw"
    Component = "storage"
    DataZone  = "raw"
  }
}
