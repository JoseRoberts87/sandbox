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

  # A short, stable fingerprint of the approved version, carried as a tag so a
  # running endpoint can be traced back to the registry version it serves.
  model_version_suffix = local.inference_enabled ? substr(sha1(var.approved_model_package_arn), 0, 8) : ""

  # Every argument the model resource sets. The name is derived from this so a
  # replacement always gets a distinct name — see the note on the resource.
  model_fingerprint = substr(sha1(jsonencode([
    var.approved_model_package_arn,
    var.endpoint_network_isolation,
    aws_iam_role.sagemaker.arn,
  ])), 0, 8)
}

resource "aws_sagemaker_model" "refund_risk" {
  # checkov:skip=CKV_AWS_370:Not available on Serverless Inference.
  # CreateEndpointConfig fails with "The network isolation is not supported for
  # serverless endpoint" — this is an API-level incompatibility, not a choice.
  # The container reaches nothing anyway: the pipeline scores in memory, and the
  # execution role grants S3 and ECR only. Revisit if D-29 is ever revised to a
  # provisioned endpoint, where isolation is supported and worth having.
  count = local.inference_enabled ? 1 : 0

  # The name carries a fingerprint of everything that defines this model.
  #
  # SageMaker models are wholly immutable, so any change replaces the resource.
  # The endpoint configuration below sets create_before_destroy, and Terraform
  # propagates that to resources it depends on when those also need replacing —
  # so the replacement is created *before* the original is destroyed. With a
  # name that did not change, CreateModel failed with "Cannot create already
  # existing model". Deriving the name from the definition means the old and new
  # models can coexist for the moment the swap takes.
  #
  # `aws_sagemaker_model` has no name_prefix argument, which is the usual way to
  # get this. If you add an argument to this resource, add it to the hash too.
  name               = "${local.name_prefix}-refund-risk-${local.model_fingerprint}"
  execution_role_arn = aws_iam_role.sagemaker.arn

  # False, and not negotiable while the endpoint is serverless — see the skip
  # above. The variable exists for a future provisioned endpoint.
  enable_network_isolation = var.endpoint_network_isolation

  primary_container {
    model_package_name = var.approved_model_package_arn
  }

  # Made explicit rather than left to propagation, so the reason above is not
  # silently undone by someone removing it from the endpoint configuration.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name      = "${local.name_prefix}-refund-risk"
    Component = "ml"

    # Which registry version a running endpoint is actually serving.
    ModelPackageVersion = local.model_version_suffix
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
