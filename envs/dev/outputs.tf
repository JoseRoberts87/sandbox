output "account_id" {
  description = "AWS account these resources were created in."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "AWS region."
  value       = var.aws_region
}

output "raw_bucket_name" {
  description = "Raw data bucket name."
  value       = module.raw.id
}

output "raw_bucket_arn" {
  description = "Raw data bucket ARN. Needed by the Glue job role in phase 2."
  value       = module.raw.arn
}

output "s3_kms_key_arn" {
  description = "KMS key ARN for the data lake buckets. Every consuming role needs kms:Decrypt on this."
  value       = aws_kms_key.s3.arn
}

output "processed_bucket_name" {
  description = "Processed (Parquet) bucket name."
  value       = module.processed.id
}

output "processed_bucket_arn" {
  description = "Processed bucket ARN. Needed by the Redshift COPY role in phase 3."
  value       = module.processed.arn
}

output "artifacts_bucket_name" {
  description = "Artifacts bucket: Glue scripts, temp, Spark logs, and later models."
  value       = module.artifacts.id
}

output "glue_job_name" {
  description = "Name of the raw -> processed Glue job."
  value       = aws_glue_job.raw_to_processed.name
}

output "glue_job_role_arn" {
  description = "Glue job execution role."
  value       = aws_iam_role.glue_job.arn
}

output "glue_raw_database" {
  description = "Glue catalog database for the raw zone (crawler output)."
  value       = aws_glue_catalog_database.raw.name
}

output "glue_processed_database" {
  description = "Glue catalog database for the processed zone. Athena and Redshift Spectrum read from here."
  value       = aws_glue_catalog_database.processed.name
}

output "glue_raw_crawler_name" {
  description = "On-demand raw crawler, if enabled."
  value       = var.enable_raw_crawler ? aws_glue_crawler.raw[0].name : null
}

output "etl_schedule_state" {
  description = "Whether the ETL schedule is currently armed."
  value       = aws_scheduler_schedule.raw_to_processed.state
}
