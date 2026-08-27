# Remote state (D-32).
#
# Kept in its own file on purpose: moving between remote and local state is then
# a matter of removing or restoring this file, rather than editing inside a
# block and risking a half-commented backend.
#
#   remote -> local :  mv backend.tf backend.tf.disabled && terraform init -migrate-state
#   local  -> remote:  mv backend.tf.disabled backend.tf && terraform init -migrate-state
#
# The bucket is NOT managed by this configuration — it cannot be, since it holds
# the state that would describe it. It is created once, by hand, and must have
# versioning enabled: that is the only thing standing between a corrupted apply
# and an unrecoverable environment.
#
# `use_lockfile` uses S3-native conditional writes for locking, so no DynamoDB
# table is needed. Requires Terraform >= 1.10 (we pin ~> 1.15, D-33).

terraform {
  backend "s3" {
    bucket = "joseroberts87-tf-backend-etl"
    key    = "envs/dev/terraform.tfstate"
    region = "us-east-1"

    encrypt      = true
    use_lockfile = true
  }
}
