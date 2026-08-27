# -----------------------------------------------------------------------------
# IAM for the ETL layer (T-2.3)
#
# Deliberately not the AWSGlueServiceRole managed policy: it grants broad S3
# access to any bucket named aws-glue-*, which is both wider than we need and
# narrower than our actual bucket names. Explicit statements below.
# -----------------------------------------------------------------------------

locals {
  glue_catalog_arns = [
    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.raw.name}",
    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.processed.name}",
    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.raw.name}/*",
    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.processed.name}/*",
  ]

  glue_log_group_arn = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*"
}

data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

# ---------------------------------- job role ----------------------------------

resource "aws_iam_role" "glue_job" {
  name               = "${local.name_prefix}-glue-job"
  description        = "Execution role for Glue ETL jobs: read raw, write processed."
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name      = "${local.name_prefix}-glue-job"
    Component = "etl"
  }
}

data "aws_iam_policy_document" "glue_job" {
  # Raw is read-only. The ETL must never be able to alter the source of truth.
  statement {
    sid       = "ReadRaw"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${module.raw.arn}/*"]
  }

  statement {
    sid       = "ListRaw"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [module.raw.arn]
  }

  # Processed is read-write: the job purges a partition before rewriting it, so
  # that a rerun replaces rather than duplicates (D-19).
  statement {
    sid       = "WriteProcessed"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${module.processed.arn}/*"]
  }

  statement {
    sid       = "ListProcessed"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [module.processed.arn]
  }

  # Scripts are read-only; temp and event logs are read-write.
  statement {
    sid       = "ReadScripts"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${module.artifacts.arn}/glue/scripts/*"]
  }

  statement {
    sid     = "WriteGlueScratch"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${module.artifacts.arn}/glue/temp/*",
      "${module.artifacts.arn}/glue/spark-logs/*",
    ]
  }

  statement {
    sid       = "ListArtifacts"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [module.artifacts.arn]
  }

  # Every bucket is SSE-KMS. Without this the failure surfaces as an opaque
  # AccessDenied from S3 rather than from KMS.
  statement {
    sid    = "UseS3Key"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.s3.arn]
  }

  statement {
    sid    = "GlueCatalog"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:CreatePartition",
      "glue:UpdatePartition",
      "glue:BatchCreatePartition",
      "glue:BatchGetPartition",
      "glue:BatchUpdatePartition",
      "glue:BatchDeletePartition",
    ]
    resources = local.glue_catalog_arns
  }

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:AssociateKmsKey"]
    resources = [local.glue_log_group_arn]
  }

  # Required by --enable-metrics / --enable-spark-ui.
  statement {
    sid       = "Metrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Glue", "AWS/Glue"]
    }
  }
}

resource "aws_iam_role_policy" "glue_job" {
  name   = "${local.name_prefix}-glue-job"
  role   = aws_iam_role.glue_job.id
  policy = data.aws_iam_policy_document.glue_job.json
}

# -------------------------------- crawler role --------------------------------
# Exploration only (D-16). Nothing downstream reads a crawled table.

resource "aws_iam_role" "glue_crawler" {
  count = var.enable_raw_crawler ? 1 : 0

  name               = "${local.name_prefix}-glue-crawler"
  description        = "Schema discovery over the raw zone. Exploration only."
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name      = "${local.name_prefix}-glue-crawler"
    Component = "etl"
  }
}

data "aws_iam_policy_document" "glue_crawler" {
  statement {
    sid       = "ReadRaw"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [module.raw.arn, "${module.raw.arn}/*"]
  }

  statement {
    sid       = "UseS3Key"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.s3.arn]
  }

  statement {
    sid    = "GlueCatalog"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:GetPartitions",
      "glue:BatchCreatePartition",
      "glue:BatchGetPartition",
      "glue:BatchUpdatePartition",
      "glue:BatchDeletePartition",
    ]
    resources = local.glue_catalog_arns
  }

  statement {
    sid       = "ReadGlueSecurityConfiguration"
    effect    = "Allow"
    actions   = ["glue:GetSecurityConfiguration"]
    resources = ["*"]
  }

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.glue_log_group_arn]
  }
}

resource "aws_iam_role_policy" "glue_crawler" {
  count = var.enable_raw_crawler ? 1 : 0

  name   = "${local.name_prefix}-glue-crawler"
  role   = aws_iam_role.glue_crawler[0].id
  policy = data.aws_iam_policy_document.glue_crawler.json
}

# ------------------------------- scheduler role -------------------------------

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Confused-deputy guard: only our own account's schedules may assume this.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name_prefix}-scheduler"
  description        = "Lets EventBridge Scheduler start the ETL job."
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json

  tags = {
    Name      = "${local.name_prefix}-scheduler"
    Component = "etl"
  }
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "StartEtlJob"
    effect    = "Allow"
    actions   = ["glue:StartJobRun"]
    resources = [aws_glue_job.raw_to_processed.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${local.name_prefix}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}
