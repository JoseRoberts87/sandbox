# -----------------------------------------------------------------------------
# Redshift Serverless (D-04, D-22, T-3.2)
#
# Serverless rather than a provisioned cluster: this workload is a batch load
# and a handful of queries, so paying for a cluster that idles 23 hours a day is
# the wrong shape. Capacity is pinned to the minimum and capped by a usage
# limit, because this is the first component in the project that can run up a
# bill on its own.
# -----------------------------------------------------------------------------

resource "aws_redshiftserverless_namespace" "main" {
  namespace_name = "${local.name_prefix}-ns"
  db_name        = var.redshift_database_name
  admin_username = var.redshift_admin_username

  # AWS generates the password and keeps it in Secrets Manager, so it is never
  # written to Terraform state in plaintext (D-25).
  manage_admin_password = true

  kms_key_id           = aws_kms_key.s3.arn
  default_iam_role_arn = aws_iam_role.redshift.arn
  iam_roles            = [aws_iam_role.redshift.arn]

  log_exports = ["userlog", "connectionlog", "useractivitylog"]

  tags = {
    Name      = "${local.name_prefix}-ns"
    Component = "warehouse"
  }
}

resource "aws_redshiftserverless_workgroup" "main" {
  namespace_name = aws_redshiftserverless_namespace.main.namespace_name
  workgroup_name = "${local.name_prefix}-wg"

  base_capacity = var.redshift_base_capacity
  max_capacity  = var.redshift_max_capacity

  # Private: reached through the Data API, never over the public internet.
  publicly_accessible = false
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.redshift.id]

  # Forces S3 traffic through the VPC and its gateway endpoint rather than the
  # Redshift-managed network. If COPY ever fails with an opaque S3 or KMS
  # timeout, this is the first thing to suspect — see the note in the README.
  enhanced_vpc_routing = var.redshift_enhanced_vpc_routing

  tags = {
    Name      = "${local.name_prefix}-wg"
    Component = "warehouse"
  }
}

# Hard ceiling on compute. There is no budget alarm yet (T-6.3), so this is the
# only thing standing between a runaway query and a surprise bill.
resource "aws_redshiftserverless_usage_limit" "compute" {
  resource_arn  = aws_redshiftserverless_workgroup.main.arn
  usage_type    = "serverless-compute"
  amount        = var.redshift_monthly_rpu_hours
  period        = "monthly"
  breach_action = var.redshift_usage_breach_action
}
