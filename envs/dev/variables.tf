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

variable "etl_max_reject_pct" {
  description = "Fail a run when more than this percentage of rows are quarantined. A few bad rows should not kill a batch; a broken feed should not load silently (D-20)."
  type        = number
  default     = 5.0
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

# ---------------------------------- network -----------------------------------

variable "vpc_cidr" {
  description = "CIDR for the VPC that exists solely because Redshift Serverless requires one."
  type        = string
  default     = "10.20.0.0/16"
}

# --------------------------------- redshift -----------------------------------

variable "redshift_database_name" {
  description = "Initial database created in the namespace."
  type        = string
  default     = "analytics"
}

variable "redshift_admin_username" {
  description = "Admin user. The password is generated and held by Secrets Manager, never by Terraform (D-25)."
  type        = string
  default     = "admin_user"
}

variable "redshift_base_capacity" {
  description = "Base RPUs. 8 is the minimum Redshift Serverless allows, and the right starting point until there is a reason to go higher."
  type        = number
  default     = 8

  validation {
    condition     = var.redshift_base_capacity >= 8 && var.redshift_base_capacity % 8 == 0
    error_message = "Base capacity must be at least 8 RPUs and a multiple of 8."
  }
}

variable "redshift_max_capacity" {
  description = "Ceiling on RPUs a query may scale to. Caps the cost of one bad query."
  type        = number
  default     = 32
}

variable "redshift_monthly_rpu_hours" {
  description = "Monthly RPU-hour allowance before the breach action fires. 8 RPUs running for an hour costs 8 RPU-hours."
  type        = number
  default     = 40
}

variable "redshift_usage_breach_action" {
  description = "What happens when the usage limit is hit: log, emit-metric or deactivate. `deactivate` stops queries — the right default while there is no budget alarm, but it will look like an outage if it fires unexpectedly."
  type        = string
  default     = "deactivate"

  validation {
    condition     = contains(["log", "emit-metric", "deactivate"], var.redshift_usage_breach_action)
    error_message = "Breach action must be log, emit-metric or deactivate."
  }
}

variable "redshift_enhanced_vpc_routing" {
  description = "Force Redshift's S3 traffic through this VPC. Better isolation, but Spectrum then also needs to reach the Glue catalog from inside the VPC, which requires interface endpoints this environment does not have (T-3.14). Leaving it on without them makes external-table reads time out after 30s."
  type        = bool
  default     = false
}

# -------------------------------- sagemaker -----------------------------------

variable "sagemaker_training_image" {
  description = "Managed scikit-learn training image. Region-specific — verify before the first run with `sagemaker.image_uris.retrieve(framework='sklearn', region=..., version='1.2-1')`. A wrong URI fails create-training-job immediately, so it is cheap to get wrong."
  type        = string
  default     = "683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-scikit-learn:1.2-1"
}

variable "sagemaker_training_instance_type" {
  description = "Training instance. The dataset is tiny; this is the smallest sensible general-purpose option."
  type        = string
  default     = "ml.m5.large"
}

variable "sagemaker_max_runtime_seconds" {
  description = "Hard stop on a training run, so a hung job cannot bill for hours."
  type        = number
  default     = 900
}

# -------------------------------- inference -----------------------------------

variable "approved_model_package_arn" {
  description = "ARN of the approved Model Registry version to serve. **Empty means no inference stack is created at all** — endpoint, Lambda and API Gateway are all gated on this. Setting it is the promotion step (D-31): approve a version, paste its ARN here, apply."
  type        = string
  default     = ""
}

variable "endpoint_memory_mb" {
  description = "Serverless Inference memory. Must be one of 1024/2048/3072/4096/5120/6144. 2048 is comfortable for an sklearn pipeline."
  type        = number
  default     = 2048

  validation {
    condition     = contains([1024, 2048, 3072, 4096, 5120, 6144], var.endpoint_memory_mb)
    error_message = "Serverless Inference memory must be 1024, 2048, 3072, 4096, 5120 or 6144 MB."
  }
}

variable "endpoint_max_concurrency" {
  description = "Concurrent invocations the serverless endpoint will scale to. Low on purpose — it is a cost ceiling as much as a capacity setting."
  type        = number
  default     = 5

  validation {
    condition     = var.endpoint_max_concurrency >= 1 && var.endpoint_max_concurrency <= 200
    error_message = "Max concurrency must be between 1 and 200."
  }
}

# ----------------------------------- api --------------------------------------

variable "predict_lambda_timeout_seconds" {
  description = "Lambda timeout. Generous relative to a warm call, because a serverless endpoint cold start can take several seconds."
  type        = number
  default     = 30
}

variable "predict_lambda_reserved_concurrency" {
  description = "Reserved concurrency for the proxy. Caps blast radius: a burst here cannot starve the rest of the account."
  type        = number
  default     = 10
}

variable "predict_required_fields" {
  description = "Fields every prediction instance must carry. Validated by the Lambda so a bad request never reaches the endpoint. **Must match the model's feature list** in `ml/train.py`; `tests/test_train.py` fails if they diverge."
  type        = list(string)
  default = [
    "region",
    "channel",
    "category",
    "quantity",
    "unit_price_usd",
    "discount_pct",
    "order_dow",
  ]
}

variable "predict_max_instances" {
  description = "Maximum rows accepted in one prediction request."
  type        = number
  default     = 100
}

variable "api_throttle_rate_limit" {
  description = "Steady-state requests per second allowed per API key."
  type        = number
  default     = 10
}

variable "api_throttle_burst_limit" {
  description = "Burst capacity above the steady rate."
  type        = number
  default     = 20
}

variable "api_daily_quota" {
  description = "Requests per key per day. The endpoint scales with demand, so an unmetered key is an unmetered bill."
  type        = number
  default     = 10000
}

variable "log_retention_days" {
  description = "Retention for log groups this configuration declares. The AWS default is never expire, which quietly accrues cost (D-40)."
  type        = number
  default     = 30
}

variable "endpoint_network_isolation" {
  description = "Cut the inference container off from the network. **Must stay false while the endpoint is serverless** — CreateEndpointConfig rejects it outright with 'network isolation is not supported for serverless endpoint'. Kept as a variable because it is both supported and correct for a provisioned real-time endpoint, which is the likely move if a latency SLO ever rules out cold starts (D-29)."
  type        = bool
  default     = false
}
