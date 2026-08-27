# -----------------------------------------------------------------------------
# Inference endpoint (D-29, phase 5)
#
# Serverless Inference: scales to zero, so an idle environment costs nothing.
# The trade is a cold start of a few seconds after inactivity, which the Lambda
# proxy surfaces as a 503 "warming up, please retry" rather than a generic 500.
#
# The whole inference stack is gated on `approved_model_package_arn`. Empty
# means no model has been approved yet, and `terraform apply` creates nothing —
# so phase 5 can be applied before phase 4 has ever produced a version.
#
# Promotion (D-31): approve a version in the Model Registry, put its ARN in
# terraform.tfvars, apply. The deployed model version is therefore recorded in
# version control and changes only through a reviewed diff.
# -----------------------------------------------------------------------------

locals {
  inference_enabled = var.approved_model_package_arn != ""

  # Ties the model resource to the exact approved version, so a new approval
  # rolls the endpoint instead of silently leaving the old model serving.
  model_version_suffix = local.inference_enabled ? substr(sha1(var.approved_model_package_arn), 0, 8) : ""
}

resource "aws_sagemaker_model" "refund_risk" {
  count = local.inference_enabled ? 1 : 0

  name               = "${local.name_prefix}-refund-risk-${local.model_version_suffix}"
  execution_role_arn = aws_iam_role.sagemaker.arn

  # The pipeline scores a row in memory and needs no network access, so cut it
  # off. SageMaker still stages the artifact before the container starts.
  # Behind a variable because if an endpoint ever fails to reach InService,
  # this is the first thing to flip while diagnosing.
  enable_network_isolation = var.endpoint_network_isolation

  primary_container {
    model_package_name = var.approved_model_package_arn
  }

  tags = {
    Name      = "${local.name_prefix}-refund-risk"
    Component = "ml"
  }
}

# Endpoint configurations are immutable, so this is name_prefix +
# create_before_destroy: a model change makes a new config and moves the
# endpoint onto it without a window where the endpoint points at nothing.
resource "aws_sagemaker_endpoint_configuration" "refund_risk" {
  # checkov:skip=CKV_AWS_98:Not applicable to Serverless Inference. kms_key_arn
  # encrypts the ML storage volume attached to a provisioned instance; a
  # serverless variant has no such volume, and setting it is rejected.
  count = local.inference_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-refund-risk-"

  production_variants {
    variant_name = "AllTraffic"
    model_name   = aws_sagemaker_model.refund_risk[0].name

    serverless_config {
      memory_size_in_mb = var.endpoint_memory_mb
      max_concurrency   = var.endpoint_max_concurrency
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name      = "${local.name_prefix}-refund-risk"
    Component = "ml"
  }
}

resource "aws_sagemaker_endpoint" "refund_risk" {
  count = local.inference_enabled ? 1 : 0

  name                 = "${local.name_prefix}-refund-risk"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.refund_risk[0].name

  tags = {
    Name      = "${local.name_prefix}-refund-risk"
    Component = "ml"
  }
}
