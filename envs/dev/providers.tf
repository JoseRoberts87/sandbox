provider "aws" {
  region = var.aws_region

  # Every resource gets these (D-36). Resource-level tags merge on top.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}
