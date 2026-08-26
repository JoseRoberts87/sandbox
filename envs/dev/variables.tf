variable "project" {
  description = "Project name. Used as the prefix for every resource name (D-36)."
  type        = string
  default     = "sandbox"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.project))
    error_message = "Project must be 2-20 lowercase alphanumeric characters or hyphens (it ends up in S3 bucket names)."
  }
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,10}$", var.environment))
    error_message = "Environment must be 2-10 lowercase alphanumeric characters or hyphens."
  }
}

variable "aws_region" {
  description = "AWS region for all resources. See Q-06 — not yet confirmed."
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Value for the Owner tag."
  type        = string
  default     = "data-platform"
}

variable "kms_key_deletion_window_days" {
  description = "Waiting period before a scheduled KMS key deletion completes. 7 is the minimum; short is fine for a disposable dev environment."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "KMS deletion window must be between 7 and 30 days."
  }
}

variable "raw_transition_days" {
  description = "Days before raw objects move to colder storage (D-14). Raw never expires — it is the source of truth for reprocessing."
  type        = number
  default     = 90
}

variable "raw_noncurrent_version_expiration_days" {
  description = "Days before superseded versions of raw objects are deleted."
  type        = number
  default     = 90
}

variable "force_destroy_buckets" {
  description = "Let `terraform destroy` delete non-empty buckets. Convenient while iterating in dev; must be false anywhere real data lives."
  type        = bool
  default     = false
}
