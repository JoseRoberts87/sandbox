# A single S3 bucket, private and encrypted by default.
#
# Deliberately minimal and reusable: the raw / processed / artifacts buckets
# (D-11) differ only in name, lifecycle, and who is granted access, so this
# module owns the security posture and the caller owns the policy.

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = var.tags
}

# Nothing in this project is ever public.
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disable ACLs entirely; access is granted by bucket policy and IAM only.
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    # Cuts KMS API calls (and cost) by ~99% for prefixes written in bulk.
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Noncurrent-version rules are only meaningful once versioning exists.
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }

  dynamic "rule" {
    for_each = var.transition_days == null ? [] : [1]

    content {
      id     = "transition-to-${lower(var.transition_storage_class)}"
      status = "Enabled"

      filter {}

      transition {
        days          = var.transition_days
        storage_class = var.transition_storage_class
      }
    }
  }

  dynamic "rule" {
    for_each = var.noncurrent_version_expiration_days == null ? [] : [1]

    content {
      id     = "expire-noncurrent-versions"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = var.noncurrent_version_expiration_days
      }
    }
  }
}

# Reject any request that is not over TLS.
data "aws_iam_policy_document" "this" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.this.json

  # A public-access-block change and a policy change can race on first apply.
  depends_on = [aws_s3_bucket_public_access_block.this]
}
