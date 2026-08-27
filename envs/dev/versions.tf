terraform {
  # Installed locally: 1.15.8. Exact provider reproducibility comes from the
  # committed .terraform.lock.hcl (D-33).
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }

    # Zips the Lambda source at plan time, so the deployed function always
    # matches the committed handler.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
