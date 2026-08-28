-- Snapshot the training set to S3 (T-4.2, D-26).
--
-- UNLOAD via the Data API rather than having SageMaker query Redshift directly:
-- the training job then needs no VPC attachment and no NAT, and the files this
-- writes ARE the reproducible artifact — "which rows did model v3 train on" is
-- answerable by looking at a prefix.
--
-- PARALLEL OFF and EXTENSION give one predictable, named, headed CSV rather
-- than a slice-per-file spray. ALLOWOVERWRITE makes re-running a version safe.
--
-- Requires: training_prefix

UNLOAD ('SELECT * FROM ml.orders_training')
TO '${training_prefix}'
IAM_ROLE '${redshift_role_arn}'
FORMAT AS CSV
HEADER
EXTENSION 'csv'
PARALLEL OFF
ALLOWOVERWRITE;
