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
# takehome/orders: schema and cleaning rules are declared in
# glue/jobs/raw_to_processed.py. See docs/dataset-takehome-orders.md.
etl_source_name   = "takehome"
etl_dataset       = "orders"
etl_source_format = "csv"

# A few bad rows are quarantined; a broken feed fails the run.
etl_max_reject_pct = 5.0

# Schedule stays disarmed until there is real data and a cadence (Q-08).
etl_schedule_enabled    = false
etl_schedule_expression = "cron(0 6 * * ? *)"

# --- network ---
vpc_cidr = "10.20.0.0/16"

# --- redshift ---
# Serverless bills per RPU-hour while queries run. 8 RPUs is the floor; the
# monthly allowance below is a hard stop, not a warning.
redshift_database_name        = "analytics"
redshift_base_capacity        = 8
redshift_max_capacity         = 32
redshift_monthly_rpu_hours    = 40
redshift_usage_breach_action  = "deactivate"
redshift_enhanced_vpc_routing = true
