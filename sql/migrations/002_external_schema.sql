-- Spectrum over the Glue catalog the ETL already maintains (D-16, D-23).
--
-- Loading through Spectrum rather than COPY is deliberate: COPY cannot populate
-- a partition column, and ingest_date exists only as a path segment. Spectrum
-- exposes it as a real column, so the load is a plain INSERT ... SELECT.

CREATE EXTERNAL SCHEMA IF NOT EXISTS processed_ext
FROM DATA CATALOG
DATABASE '${glue_database}'
IAM_ROLE '${redshift_role_arn}'
REGION '${aws_region}';
