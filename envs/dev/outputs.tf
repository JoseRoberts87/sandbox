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

output "redshift_workgroup_name" {
  description = "Redshift Serverless workgroup, for the Data API."
  value       = aws_redshiftserverless_workgroup.main.workgroup_name
}

output "redshift_namespace_name" {
  description = "Redshift Serverless namespace."
  value       = aws_redshiftserverless_namespace.main.namespace_name
}

output "redshift_database_name" {
  description = "Database to target with --database on Data API calls."
  value       = aws_redshiftserverless_namespace.main.db_name
}

output "redshift_admin_secret_arn" {
  description = "Secrets Manager ARN holding the AWS-managed admin credentials."
  value       = aws_redshiftserverless_namespace.main.admin_password_secret_arn
}

output "redshift_role_arn" {
  description = "IAM role Redshift assumes for S3 and Glue catalog access. Needed by CREATE EXTERNAL SCHEMA."
  value       = aws_iam_role.redshift.arn
}

output "redshift_endpoint" {
  description = "Workgroup endpoint. Unused while everything goes through the Data API."
  value       = try(aws_redshiftserverless_workgroup.main.endpoint[0].address, null)
}

output "sagemaker_role_arn" {
  description = "SageMaker execution role, for training jobs and endpoints."
  value       = aws_iam_role.sagemaker.arn
}

output "sagemaker_model_package_group" {
  description = "Model Registry group. New versions register as PendingManualApproval (D-31)."
  value       = aws_sagemaker_model_package_group.refund_risk.model_package_group_name
}

output "sagemaker_training_image" {
  description = "Managed container used for training."
  value       = var.sagemaker_training_image
}

output "sagemaker_training_instance_type" {
  description = "Instance type used for training runs."
  value       = var.sagemaker_training_instance_type
}

output "sagemaker_max_runtime_seconds" {
  description = "Training job timeout."
  value       = var.sagemaker_max_runtime_seconds
}

output "inference_enabled" {
  description = "Whether an approved model is configured. False means the endpoint, Lambda and API do not exist."
  value       = local.inference_enabled
}

output "endpoint_name" {
  description = "SageMaker Serverless endpoint serving the approved model."
  value       = local.inference_enabled ? aws_sagemaker_endpoint.refund_risk[0].name : null
}

output "predict_url" {
  description = "Public prediction URL. Requires the x-api-key header."
  value       = local.inference_enabled ? "${aws_api_gateway_stage.predict[0].invoke_url}/predict" : null
}

output "predict_api_key_id" {
  description = "API key ID. Read the value with `aws apigateway get-api-key --api-key <id> --include-value`."
  value       = local.inference_enabled ? aws_api_gateway_api_key.predict[0].id : null
}

output "deployed_model_package_arn" {
  description = "Model Registry version currently being served."
  value       = var.approved_model_package_arn != "" ? var.approved_model_package_arn : null
}

output "etl_source_name" {
  description = "Source segment of the dataset prefix. Scripts read this so the path is defined in one place."
  value       = var.etl_source_name
}

output "etl_dataset" {
  description = "Dataset segment of the dataset prefix."
  value       = var.etl_dataset
}

output "sample_data_key" {
  description = "Where the seeded sample file lands in the raw zone, if seeding is on."
  value       = var.seed_sample_data ? aws_s3_object.sample_data[0].key : null
}

output "predict_required_fields" {
  description = "Fields the API requires on every instance. Read by the smoke test so it cannot fall behind the deployed contract."
  value       = var.predict_required_fields
}

output "environment" {
  description = "Environment name. Also the API Gateway stage name."
  value       = var.environment
}
