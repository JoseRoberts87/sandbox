terraform {
  # Installed locally: 1.9.8. Upper bound guards against a 2.x that has not
  # shipped yet; exact provider reproducibility comes from the committed
  # .terraform.lock.hcl (D-33).
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }

  # ---------------------------------------------------------------------------
  # State is LOCAL for now — ./terraform.tfstate, gitignored.
  #
  # Migration to remote state (D-32), once the state bucket exists:
  #   1. Create the state bucket (versioned, encrypted, public access blocked).
  #   2. Uncomment the block below and fill in the bucket name.
  #   3. terraform init -migrate-state
  #   4. Verify, then delete the local terraform.tfstate* files.
  #
  # `use_lockfile` needs Terraform >= 1.10; on 1.9.8 use a DynamoDB lock table
  # instead. Worth upgrading Terraform before migrating to skip the table.
  #
  # backend "s3" {
  #   bucket       = "sandbox-dev-tfstate-<account-id>"
  #   key          = "envs/dev/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
  # ---------------------------------------------------------------------------
}
