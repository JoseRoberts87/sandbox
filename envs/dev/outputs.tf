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
