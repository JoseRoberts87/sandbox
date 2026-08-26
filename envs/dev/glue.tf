# -----------------------------------------------------------------------------
# Glue ETL (D-03, phase 2)
#
# raw (as-landed CSV/JSON)  ->  Glue PySpark job  ->  processed (Parquet)
#
# Layout on both sides is <source>/<dataset>/ingest_date=YYYY-MM-DD/ (D-12,
# docs/data-layout.md), so a run is addressed by a single date and rerunning a
# date replaces that partition rather than appending to it.
# -----------------------------------------------------------------------------

# ------------------------------ catalog databases ------------------------------
# One database per zone. Tables for the raw zone are discovered (crawler,
# exploration only); tables for the processed zone are written by the job and
# will move into Terraform once the schema is known and fixed — see T-2.10.

resource "aws_glue_catalog_database" "raw" {
  name        = "${local.catalog_prefix}_raw"
  description = "Raw zone, as-landed. Discovered by crawler; exploration only (D-16)."
}

resource "aws_glue_catalog_database" "processed" {
  name        = "${local.catalog_prefix}_processed"
  description = "Processed zone, Parquet. Read by Athena and by Redshift COPY."
}

# ------------------------------- job script (D-38) -----------------------------
# Terraform uploads the script so the deployed job always matches the commit.
# source_hash rather than etag: KMS-encrypted objects do not expose an MD5 etag,
# so etag-based drift detection would fire on every plan.

resource "aws_s3_object" "raw_to_processed_script" {
  bucket = module.artifacts.id
  key    = "glue/scripts/raw_to_processed.py"

  source      = "${path.module}/../../glue/jobs/raw_to_processed.py"
  source_hash = filemd5("${path.module}/../../glue/jobs/raw_to_processed.py")

  tags = {
    Name      = "raw_to_processed.py"
    Component = "etl"
  }
}

# --------------------------- security configuration ----------------------------
# Enforces the encryption mode at the Glue level rather than relying only on the
# buckets' default encryption.
#
# CloudWatch encryption is deliberately DISABLED: encrypting Glue's log group
# with our CMK also requires a key-policy grant to logs.<region>.amazonaws.com,
# and getting that wrong silently breaks log delivery for every run. Tracked as
# T-6.6, to be applied and verified against a real account.

resource "aws_glue_security_configuration" "etl" {
  # checkov:skip=CKV_AWS_99:Legitimate finding, deliberately deferred — not a
  # false positive. CKV_AWS_99 requires all three modes encrypted, including
  # CloudWatch. Doing that needs a KMS key-policy grant to
  # logs.<region>.amazonaws.com; an incorrect policy silently breaks log
  # delivery for every job run, and it cannot be verified without applying
  # against a real account. T-6.6 implements and verifies it, then removes this.
  name = "${local.name_prefix}-etl"

  encryption_configuration {
    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = aws_kms_key.s3.arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = aws_kms_key.s3.arn
    }

    cloudwatch_encryption {
      cloudwatch_encryption_mode = "DISABLED"
    }
  }
}

# ----------------------------------- the job -----------------------------------

resource "aws_glue_job" "raw_to_processed" {
  name        = "${local.name_prefix}-raw-to-processed"
  description = "Reads one ingest_date partition from raw, writes partitioned Parquet to processed."
  role_arn    = aws_iam_role.glue_job.arn

  security_configuration = aws_glue_security_configuration.etl.name

  glue_version      = var.glue_version
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  timeout           = var.glue_timeout_minutes

  # The job is idempotent, so a retry is safe — but a silent retry also hides
  # failures. Surface them instead while the pipeline is new.
  max_retries = 0

  command {
    name            = "glueetl"
    script_location = "s3://${module.artifacts.id}/${aws_s3_object.raw_to_processed_script.key}"
    python_version  = "3"
  }

  # One run at a time: two concurrent runs on the same date would race on the
  # same processed partition.
  execution_property {
    max_concurrent_runs = 1
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--TempDir"                          = "s3://${module.artifacts.id}/glue/temp/"
    "--spark-event-logs-path"            = "s3://${module.artifacts.id}/glue/spark-logs/"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    "--enable-spark-ui"                  = "true"

    # Bookmarks off (revision to D-19). Partitions are addressed explicitly by
    # date, which makes reruns and backfills the same code path and keeps all
    # progress state visible in S3 rather than hidden in the Glue service.
    "--job-bookmark-option" = "job-bookmark-disable"

    # Job parameters — override per run with `aws glue start-job-run --arguments`.
    "--raw_bucket"         = module.raw.id
    "--processed_bucket"   = module.processed.id
    "--processed_database" = aws_glue_catalog_database.processed.name
    "--source_name"        = var.etl_source_name
    "--dataset"            = var.etl_dataset
    "--source_format"      = var.etl_source_format
    "--ingest_date"        = "latest"
    "--update_catalog"     = "true"
    "--csv_header"         = "true"
    "--csv_infer_schema"   = "true"
    "--required_columns"   = ""
  }

  tags = {
    Name      = "${local.name_prefix}-raw-to-processed"
    Component = "etl"
  }
}

# --------------------------- raw crawler (exploration) -------------------------
# On demand, no schedule. Its purpose is answering "what is actually in this
# file" so the real schema can be declared (Q-01, Q-02). Production reads never
# depend on a crawled table.

resource "aws_glue_crawler" "raw" {
  count = var.enable_raw_crawler ? 1 : 0

  name          = "${local.name_prefix}-raw"
  description   = "Schema discovery over the raw zone. Run on demand."
  role          = aws_iam_role.glue_crawler[0].arn
  database_name = aws_glue_catalog_database.raw.name
  table_prefix  = "raw_"

  security_configuration = aws_glue_security_configuration.etl.name

  s3_target {
    path = "s3://${module.raw.id}/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = {
    Name      = "${local.name_prefix}-raw"
    Component = "etl"
  }
}

# --------------------------------- schedule ------------------------------------
# Created disabled. Cadence is unanswered (Q-08) and there is no real data yet,
# so nothing should fire on its own until both are settled (D-17, D-18).

resource "aws_scheduler_schedule" "raw_to_processed" {
  name        = "${local.name_prefix}-raw-to-processed"
  description = "Daily trigger for the raw -> processed Glue job."
  state       = var.etl_schedule_enabled ? "ENABLED" : "DISABLED"

  schedule_expression          = var.etl_schedule_expression
  schedule_expression_timezone = "UTC"
  kms_key_arn                  = aws_kms_key.s3.arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:glue:startJobRun"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      JobName = aws_glue_job.raw_to_processed.name
    })

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
