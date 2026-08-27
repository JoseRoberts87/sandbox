# -----------------------------------------------------------------------------
# Public front door (D-30, T-5.3)
#
# A SageMaker endpoint is not publicly callable — every request must be
# SigV4-signed with IAM credentials. Consumers here are outside AWS (Q-04), so
# the endpoint gets a front door: API Gateway holds the API key and the
# throttle, and a Lambda holds the IAM identity that can actually invoke.
#
# Created only alongside an approved model — see the note in inference.tf.
# -----------------------------------------------------------------------------

data "archive_file" "predict_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/predict"
  output_path = "${path.module}/.terraform/predict_lambda.zip"
}

# ------------------------------- lambda proxy ---------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "predict_lambda" {
  count = local.inference_enabled ? 1 : 0

  name               = "${local.name_prefix}-predict"
  description        = "Lets the API proxy invoke the refund-risk endpoint."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name      = "${local.name_prefix}-predict"
    Component = "ml"
  }
}

data "aws_iam_policy_document" "predict_lambda" {
  count = local.inference_enabled ? 1 : 0

  # One endpoint, one action. This role can do nothing else.
  statement {
    sid       = "InvokeEndpoint"
    effect    = "Allow"
    actions   = ["sagemaker:InvokeEndpoint"]
    resources = [aws_sagemaker_endpoint.refund_risk[0].arn]
  }

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.predict_lambda[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "predict_lambda" {
  count = local.inference_enabled ? 1 : 0

  name   = "${local.name_prefix}-predict"
  role   = aws_iam_role.predict_lambda[0].id
  policy = data.aws_iam_policy_document.predict_lambda[0].json
}

# Declared rather than left to Lambda's implicit creation, which defaults to
# never expiring (D-40).
resource "aws_cloudwatch_log_group" "predict_lambda" {
  # checkov:skip=CKV_AWS_338:Retention is a deliberate choice, not an oversight
  # — `log_retention_days`, 30 by default. A year of dev logs is cost without a
  # reader (D-39). Revisit per environment for prod — T-6.9.
  count = local.inference_enabled ? 1 : 0

  name              = "/aws/lambda/${local.name_prefix}-predict"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn

  tags = {
    Name      = "${local.name_prefix}-predict"
    Component = "ml"
  }
}

resource "aws_lambda_function" "predict" {
  # checkov:skip=CKV_AWS_116:A DLQ only catches failed *asynchronous*
  # invocations. API Gateway invokes synchronously, so a failure returns to the
  # caller as a 502/503 — there is nothing for a DLQ to collect.
  # checkov:skip=CKV_AWS_117:Deliberate (D-37). Reaching the SageMaker runtime
  # API from inside the VPC needs a NAT gateway or an interface endpoint, and
  # this environment has neither by design. The function holds no data and
  # talks to exactly one AWS API. Revisit for prod — T-6.7.
  # checkov:skip=CKV_AWS_173:The two variables here are an endpoint name and a
  # row limit. Neither is a secret, and Lambda already encrypts variables at
  # rest with an AWS-managed key.
  # checkov:skip=CKV_AWS_272:Code signing is a real supply-chain control, but
  # the package here is zipped by Terraform from a committed file and pinned by
  # source_code_hash, so the deployed function already matches the repo.
  # Warranted once code arrives from anywhere else — T-6.8.
  count = local.inference_enabled ? 1 : 0

  function_name = "${local.name_prefix}-predict"
  description   = "Validates a prediction request and forwards it to SageMaker."
  role          = aws_iam_role.predict_lambda[0].arn

  filename         = data.archive_file.predict_lambda.output_path
  source_code_hash = data.archive_file.predict_lambda.output_base64sha256
  handler          = "handler.handler"
  runtime          = "python3.12"

  # Longer than a warm call needs, to absorb a serverless cold start.
  timeout     = var.predict_lambda_timeout_seconds
  memory_size = 256

  # Caps blast radius: a burst against this API cannot exhaust the account's
  # Lambda concurrency and starve everything else.
  reserved_concurrent_executions = var.predict_lambda_reserved_concurrency

  environment {
    variables = {
      ENDPOINT_NAME = aws_sagemaker_endpoint.refund_risk[0].name
      MAX_INSTANCES = tostring(var.predict_max_instances)
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.predict_lambda]

  tags = {
    Name      = "${local.name_prefix}-predict"
    Component = "ml"
  }
}

# --------------------------------- api gateway --------------------------------
# REST rather than HTTP API: API keys and usage plans are the reason this front
# door exists, and HTTP APIs do not support them natively.

resource "aws_api_gateway_rest_api" "predict" {
  count = local.inference_enabled ? 1 : 0

  name        = "${local.name_prefix}-predict"
  description = "Public front door for the refund-risk model."

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name      = "${local.name_prefix}-predict"
    Component = "ml"
  }
}

resource "aws_api_gateway_resource" "predict" {
  count = local.inference_enabled ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.predict[0].id
  parent_id   = aws_api_gateway_rest_api.predict[0].root_resource_id
  path_part   = "predict"
}

resource "aws_api_gateway_method" "predict_post" {
  count = local.inference_enabled ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.predict[0].id
  resource_id   = aws_api_gateway_resource.predict[0].id
  http_method   = "POST"
  authorization = "NONE"

  # The API key is the credential. Callers are outside AWS and have no IAM
  # identity, so IAM authorization is not available here; the key plus the
  # usage plan below is what gates and meters access.
  api_key_required = true

  request_validator_id = aws_api_gateway_request_validator.predict[0].id
}

# Rejects an empty body at the edge, so a malformed request never reaches the
# Lambda or the endpoint.
resource "aws_api_gateway_request_validator" "predict" {
  count = local.inference_enabled ? 1 : 0

  name                        = "${local.name_prefix}-predict"
  rest_api_id                 = aws_api_gateway_rest_api.predict[0].id
  validate_request_body       = false
  validate_request_parameters = true
}

resource "aws_api_gateway_integration" "predict" {
  count = local.inference_enabled ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.predict[0].id
  resource_id = aws_api_gateway_resource.predict[0].id
  http_method = aws_api_gateway_method.predict_post[0].http_method

  # AWS_PROXY: the Lambda sees the raw request and owns the response shape.
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.predict[0].invoke_arn
}

resource "aws_lambda_permission" "api_gateway" {
  count = local.inference_enabled ? 1 : 0

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.predict[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.predict[0].execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "predict" {
  count = local.inference_enabled ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.predict[0].id

  # Without this, editing a method or integration changes nothing that is
  # actually being served: API Gateway serves the last deployment.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.predict[0].id,
      aws_api_gateway_method.predict_post[0].id,
      aws_api_gateway_integration.predict[0].id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "api_access" {
  # checkov:skip=CKV_AWS_338:Retention is a deliberate choice, not an oversight
  # — `log_retention_days`, 30 by default. A year of dev logs is cost without a
  # reader (D-39). Revisit per environment for prod — T-6.9.
  count = local.inference_enabled ? 1 : 0

  name              = "/aws/apigateway/${local.name_prefix}-predict"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn

  tags = {
    Name      = "${local.name_prefix}-predict-access"
    Component = "ml"
  }
}

resource "aws_api_gateway_stage" "predict" {
  # checkov:skip=CKV_AWS_120:Caching is wrong for this API, not merely absent.
  # Identical payloads would return a cached score after the model behind them
  # has been replaced, which is the exact failure a prediction API must not
  # have. It is also a provisioned per-hour charge in an environment meant to
  # idle at zero.
  count = local.inference_enabled ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.predict[0].id
  deployment_id = aws_api_gateway_deployment.predict[0].id
  stage_name    = var.environment

  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access[0].arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      latency        = "$context.responseLatency"
      apiKeyId       = "$context.identity.apiKeyId"
    })
  }

  tags = {
    Name      = "${local.name_prefix}-predict"
    Component = "ml"
  }
}

resource "aws_api_gateway_method_settings" "predict" {
  # checkov:skip=CKV_AWS_225:See the caching note on the stage above.
  count = local.inference_enabled ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.predict[0].id
  stage_name  = aws_api_gateway_stage.predict[0].stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = true
    logging_level   = "ERROR"

    # Second line of defence behind the usage plan: caps the whole stage even
    # if a key's plan is misconfigured.
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
  }
}

# ------------------------------- key and quota --------------------------------

resource "aws_api_gateway_api_key" "predict" {
  count = local.inference_enabled ? 1 : 0

  name        = "${local.name_prefix}-predict"
  description = "Issued to the external consumer of the refund-risk API."
  enabled     = true

  tags = {
    Name      = "${local.name_prefix}-predict"
    Component = "ml"
  }
}

resource "aws_api_gateway_usage_plan" "predict" {
  count = local.inference_enabled ? 1 : 0

  name        = "${local.name_prefix}-predict"
  description = "Throttle and daily quota for the refund-risk API."

  api_stages {
    api_id = aws_api_gateway_rest_api.predict[0].id
    stage  = aws_api_gateway_stage.predict[0].stage_name
  }

  throttle_settings {
    rate_limit  = var.api_throttle_rate_limit
    burst_limit = var.api_throttle_burst_limit
  }

  # The endpoint scales with demand, so an unmetered key is an unmetered bill.
  quota_settings {
    limit  = var.api_daily_quota
    period = "DAY"
  }
}

resource "aws_api_gateway_usage_plan_key" "predict" {
  count = local.inference_enabled ? 1 : 0

  key_id        = aws_api_gateway_api_key.predict[0].id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.predict[0].id
}
