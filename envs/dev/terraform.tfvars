# Non-secret configuration for the dev environment.
# Never put credentials here — this file is committed.

project     = "sandbox"
environment = "dev"
aws_region  = "us-east-1" # Q-06: confirm before the first apply

owner = "data-platform"

# Raw data is the source of truth: it moves to cold storage but never expires.
raw_transition_days                    = 90
raw_noncurrent_version_expiration_days = 90

# Set true only while iterating on an empty dev bucket.
force_destroy_buckets = false
