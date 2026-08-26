# Non-secret configuration for the dev environment.
# Never put credentials here — this file is committed.

project     = "sandbox"
environment = "dev"
aws_region  = "us-east-1"

owner = "data-platform"

# Raw data is the source of truth: it moves to cold storage but never expires.
raw_transition_days                    = 90
raw_noncurrent_version_expiration_days = 90

# Set true only while iterating on an empty dev bucket.
force_destroy_buckets = false

# --- storage ---
artifacts_noncurrent_version_expiration_days = 180
glue_scratch_expiration_days                 = 7

# --- glue ---
glue_version           = "5.0"
glue_worker_type       = "G.1X"
glue_number_of_workers = 2
glue_timeout_minutes   = 60
enable_raw_crawler     = true

# --- etl job defaults ---
# Placeholders until Q-01 tells us the real source and dataset names.
etl_source_name   = "manual"
etl_dataset       = "sample"
etl_source_format = "csv"

# Schedule stays disarmed until there is real data and a cadence (Q-08).
etl_schedule_enabled    = false
etl_schedule_expression = "cron(0 6 * * ? *)"
