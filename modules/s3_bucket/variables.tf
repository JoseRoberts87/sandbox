variable "bucket_name" {
  description = "Globally unique S3 bucket name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Bucket name must be 3-63 chars, lowercase alphanumeric, hyphens or dots, and start/end alphanumeric."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN for default encryption. Null uses SSE-S3 (AES256) instead."
  type        = string
  default     = null
}

variable "versioning_enabled" {
  description = "Enable object versioning. Protects against accidental overwrite/delete."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete a non-empty bucket. Keep false for anything holding real data."
  type        = bool
  default     = false
}

variable "transition_days" {
  description = "Days before current objects transition to a colder storage class. Null disables the rule."
  type        = number
  default     = null
}

variable "transition_storage_class" {
  description = "Target storage class for the transition rule."
  type        = string
  default     = "GLACIER_IR"

  validation {
    condition = contains([
      "STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING",
      "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"
    ], var.transition_storage_class)
    error_message = "Invalid S3 storage class."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days before noncurrent object versions are deleted. Null keeps them forever."
  type        = number
  default     = null
}

variable "abort_incomplete_multipart_days" {
  description = "Days before incomplete multipart uploads are aborted. These are billable but invisible in the console."
  type        = number
  default     = 7
}

variable "expiring_prefixes" {
  description = "Per-prefix expiration rules, for transient data such as Glue temp and Spark event logs."
  type = list(object({
    prefix = string
    days   = number
  }))
  default = []
}

variable "tags" {
  description = "Tags merged with the provider's default_tags."
  type        = map(string)
  default     = {}
}
