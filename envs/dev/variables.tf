variable "project" {
  description = "Project name. Used as the prefix for every resource name (D-36)."
  type        = string
  default     = "sandbox"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.project))
    error_message = "Project must be 2-20 lowercase alphanumeric characters or hyphens (it ends up in S3 bucket names)."
  }
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,10}$", var.environment))
    error_message = "Environment must be 2-10 lowercase alphanumeric characters or hyphens."
  }
}

variable "aws_region" {
  description = "AWS region for all resources. See Q-06 — not yet confirmed."
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Value for the Owner tag."
  type        = string
  default     = "data-platform"
}

variable "kms_key_deletion_window_days" {
  description = "Waiting period before a scheduled KMS key deletion completes. 7 is the minimum; short is fine for a disposable dev environment."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "KMS deletion window must be between 7 and 30 days."
  }
}

variable "raw_transition_days" {
  description = "Days before raw objects move to colder storage (D-14). Raw never expires — it is the source of truth for reprocessing."
  type        = number
  default     = 90
}

variable "raw_noncurrent_version_expiration_days" {
  description = "Days before superseded versions of raw objects are deleted."
  type        = number
  default     = 90
}

variable "force_destroy_buckets" {
  description = "Let `terraform destroy` delete non-empty buckets. Convenient while iterating in dev; must be false anywhere real data lives."
  type        = bool
  default     = false
}

# ------------------------------- storage: zones -------------------------------

variable "artifacts_noncurrent_version_expiration_days" {
  description = "Days before superseded versions of artifacts (scripts, models) are deleted."
  type        = number
  default     = 180
}

variable "glue_scratch_expiration_days" {
  description = "Days before Glue temp and Spark event-log objects expire. Scratch data that is billed for indefinitely if left alone."
  type        = number
  default     = 7
}

# ----------------------------------- glue -------------------------------------

variable "glue_version" {
  description = "AWS Glue version. 5.0 is Spark 3.5 / Python 3.11."
  type        = string
  default     = "5.0"
}

variable "glue_worker_type" {
  description = "Glue worker type. G.1X is 4 vCPU / 16GB — the right starting point until data volume is known (Q-05)."
  type        = string
  default     = "G.1X"

  validation {
    condition     = contains(["G.1X", "G.2X", "G.4X", "G.8X", "G.025X"], var.glue_worker_type)
    error_message = "Invalid Glue worker type."
  }
}

variable "glue_number_of_workers" {
  description = "Number of Glue workers. 2 is the minimum and is plenty for small batches."
  type        = number
  default     = 2

  validation {
    condition     = var.glue_number_of_workers >= 2
    error_message = "Glue requires at least 2 workers."
  }
}

variable "glue_timeout_minutes" {
  description = "Job timeout. Low on purpose — a job that hangs should fail fast rather than bill for the AWS default of 48 hours."
  type        = number
  default     = 60
}

variable "enable_raw_crawler" {
  description = "Create the on-demand raw-zone crawler used for schema discovery (D-16). Exploration only; nothing downstream reads a crawled table."
  type        = bool
  default     = true
}

# ------------------------------ etl job defaults ------------------------------
# Defaults baked into the job definition. Override per run with
# `aws glue start-job-run --arguments '{"--ingest_date":"2026-08-01"}'`.

variable "etl_source_name" {
  description = "Default source segment of the data path. Placeholder until Q-01 is answered."
  type        = string
  default     = "manual"
}

variable "etl_dataset" {
  description = "Default dataset segment of the data path. Placeholder until Q-01 is answered."
  type        = string
  default     = "sample"
}

variable "etl_source_format" {
  description = "Default raw file format: csv, json or parquet."
  type        = string
  default     = "csv"

  validation {
    condition     = contains(["csv", "json", "parquet"], var.etl_source_format)
    error_message = "Source format must be csv, json or parquet."
  }
}

variable "etl_schedule_enabled" {
  description = "Whether the ETL schedule fires. Off until cadence (Q-08) is settled and real data is landing."
  type        = bool
  default     = false
}

variable "etl_schedule_expression" {
  description = "EventBridge Scheduler expression, evaluated in UTC."
  type        = string
  default     = "cron(0 6 * * ? *)"
}
