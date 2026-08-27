# -----------------------------------------------------------------------------
# SageMaker (D-05, phase 4)
#
# Terraform owns the durable pieces — the execution role and the model registry.
# Training runs and model versions are runtime artifacts produced by
# scripts/train_model.sh, not infrastructure (D-38): a retrain should not require
# a terraform apply, and every candidate should be reviewable before it is
# approved (D-31).
# -----------------------------------------------------------------------------

locals {
  # 683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-scikit-learn:1.2-1
  #   -> arn:aws:ecr:us-east-1:683313688378:repository/sagemaker-scikit-learn
  training_image_account    = split(".", var.sagemaker_training_image)[0]
  training_image_repository = split(":", split("/", var.sagemaker_training_image)[1])[0]

  training_image_repository_arn = join("", [
    "arn:aws:ecr:", var.aws_region, ":", local.training_image_account,
    ":repository/", local.training_image_repository,
  ])
}

resource "aws_sagemaker_model_package_group" "refund_risk" {
  model_package_group_name        = "${local.name_prefix}-orders-refund-risk"
  model_package_group_description = "Refund-risk classifier for takehome/orders. Versions register as PendingManualApproval."

  tags = {
    Name      = "${local.name_prefix}-orders-refund-risk"
    Component = "ml"
  }
}

data "aws_iam_policy_document" "sagemaker_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "sagemaker" {
  name               = "${local.name_prefix}-sagemaker"
  description        = "Execution role for SageMaker training jobs and endpoints."
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume_role.json

  tags = {
    Name      = "${local.name_prefix}-sagemaker"
    Component = "ml"
  }
}

data "aws_iam_policy_document" "sagemaker" {
  # Training data and packaged source code in; model artifacts out. Scoped to
  # prefixes so a training job cannot read the rest of the lake.
  statement {
    sid     = "ReadTrainingInputs"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = [
      "${module.artifacts.arn}/training/*",
      "${module.artifacts.arn}/code/*",
    ]
  }

  statement {
    sid       = "WriteModelArtifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${module.artifacts.arn}/models/*"]
  }

  statement {
    sid       = "ListArtifacts"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [module.artifacts.arn]
  }

  statement {
    sid    = "UseS3Key"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.s3.arn]
  }

  # GetAuthorizationToken has no resource form in IAM at all, so "*" here is the
  # only expressible grant.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # The layer pulls are scopeable, so scope them — to the single AWS-owned
  # repository holding the managed image, derived from the configured URI.
  statement {
    sid    = "PullTrainingImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [local.training_image_repository_arn]
  }

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/*"]
  }

  statement {
    sid       = "Metrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["/aws/sagemaker/TrainingJobs", "AWS/SageMaker"]
    }
  }
}

resource "aws_iam_role_policy" "sagemaker" {
  name   = "${local.name_prefix}-sagemaker"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}
