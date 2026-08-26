data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # S3 bucket names are globally unique across all of AWS, so every bucket
  # carries a suffix. Note this one is not account-scoped: if another AWS
  # account has already taken the name, creation fails with BucketAlreadyExists.
  bucket_suffix = var.owner

  # Glue catalog names cannot contain hyphens.
  catalog_prefix = replace(local.name_prefix, "-", "_")
}
