# -----------------------------------------------------------------------------
# Data lake buckets (D-11 — one bucket per zone, so IAM can be scoped per zone)
#
# Layout for raw and processed is documented in docs/data-layout.md (D-12):
#   <source>/<dataset>/ingest_date=YYYY-MM-DD/<file>
# -----------------------------------------------------------------------------

# Raw zone. Data lands here exactly as received and is never modified in place.
# Everything downstream is regenerable from this bucket, which is why versioning
# is on and nothing expires.
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

# Processed zone. Parquet written by Glue, read by Redshift COPY and Athena.
# Regenerable from raw by rerunning the job, so versioning is off — the cost of
# keeping every superseded version of a rewritten partition is not worth it.
module "processed" {
  source = "../../modules/s3_bucket"

  bucket_name = "${local.name_prefix}-processed-${local.bucket_suffix}"
  kms_key_arn = aws_kms_key.s3.arn

  versioning_enabled = false
  force_destroy      = var.force_destroy_buckets

  tags = {
    Name      = "${local.name_prefix}-processed"
    Component = "storage"
    DataZone  = "processed"
  }
}

# Artifacts zone: Glue job scripts, Glue temp/shuffle, Spark event logs, and
# later the training sets and model artifacts. Versioned, because the deployed
# script and the model that produced a prediction both need history.
module "artifacts" {
  source = "../../modules/s3_bucket"

  bucket_name = "${local.name_prefix}-artifacts-${local.bucket_suffix}"
  kms_key_arn = aws_kms_key.s3.arn

  versioning_enabled                 = true
  noncurrent_version_expiration_days = var.artifacts_noncurrent_version_expiration_days
  force_destroy                      = var.force_destroy_buckets

  # Glue's temp and event-log output is scratch. Left alone it accumulates
  # silently and is charged for indefinitely.
  expiring_prefixes = [
    { prefix = "glue/temp/", days = var.glue_scratch_expiration_days },
    { prefix = "glue/spark-logs/", days = var.glue_scratch_expiration_days },
  ]

  tags = {
    Name      = "${local.name_prefix}-artifacts"
    Component = "storage"
    DataZone  = "artifacts"
  }
}

resource "aws_s3_object" "raw_dataset_prefix" {
  bucket                 = module.raw.id
  key                    = "${var.etl_source_name}/${var.etl_dataset}/"
  content                = ""
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.s3.arn
  depends_on = [
    module.raw
  ]
}