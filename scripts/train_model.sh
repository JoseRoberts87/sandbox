#!/usr/bin/env bash
#
# Produce a candidate model version, end to end:
#
#   1. UNLOAD ml.orders_training to a versioned prefix
#   2. package ml/ as the training source
#   3. run a SageMaker training job
#   4. register the result as PendingManualApproval
#
# Nothing here is deployed by this script. Promotion to an endpoint stays a
# separate, deliberate act (D-31).
#
#   scripts/train_model.sh            # version = current UTC timestamp
#   scripts/train_model.sh 20260827T0100Z

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }

if ! ARTIFACTS=$(tf_output artifacts_bucket_name); then
  echo "error: could not read terraform outputs. Is phase 4 applied?" >&2
  exit 1
fi

ROLE_ARN=$(tf_output sagemaker_role_arn)
IMAGE=$(tf_output sagemaker_training_image)
INSTANCE_TYPE=$(tf_output sagemaker_training_instance_type)
MAX_RUNTIME=$(tf_output sagemaker_max_runtime_seconds)
GROUP=$(tf_output sagemaker_model_package_group)
KMS_KEY=$(tf_output s3_kms_key_arn)

TRAINING_URI="s3://$ARTIFACTS/training/$VERSION/"
SOURCE_URI="s3://$ARTIFACTS/code/$VERSION/sourcedir.tar.gz"
OUTPUT_URI="s3://$ARTIFACTS/models/"
JOB_NAME="orders-refund-risk-$VERSION"

echo "==> 1/4 unloading training set to $TRAINING_URI"
scripts/redshift_sql.sh sql/unload_training_set.sql "training_prefix=${TRAINING_URI}orders_"

echo "==> 2/4 packaging training source to $SOURCE_URI"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
# All three: train.py runs in the training container, inference.py in the
# endpoint, and both import the feature list and text cleaning from features.py
# so they cannot drift (D-27). features.py must be present in the archive or the
# fitted pipeline will not unpickle at inference time.
tar -czf "$STAGING/sourcedir.tar.gz" -C ml features.py train.py inference.py
aws s3 cp "$STAGING/sourcedir.tar.gz" "$SOURCE_URI"

echo "==> 3/4 training job $JOB_NAME"
python3 - "$STAGING/job.json" <<PY
import json, sys
json.dump({
    "TrainingJobName": "$JOB_NAME",
    "RoleArn": "$ROLE_ARN",
    "AlgorithmSpecification": {"TrainingImage": "$IMAGE", "TrainingInputMode": "File"},
    # Script mode: the framework container reads these two to find and run our code.
    "HyperParameters": {
        "sagemaker_program": json.dumps("train.py"),
        "sagemaker_submit_directory": json.dumps("$SOURCE_URI"),
    },
    # Passed as an environment variable rather than a hyperparameter so it is
    # not subject to the container's JSON decoding of hyperparameter values.
    "Environment": {"TRAINING_DATA_URI": "$TRAINING_URI"},
    "InputDataConfig": [{
        "ChannelName": "train",
        "ContentType": "text/csv",
        "DataSource": {"S3DataSource": {
            "S3DataType": "S3Prefix",
            "S3Uri": "$TRAINING_URI",
            "S3DataDistributionType": "FullyReplicated",
        }},
    }],
    "OutputDataConfig": {"S3OutputPath": "$OUTPUT_URI", "KmsKeyId": "$KMS_KEY"},
    "ResourceConfig": {"InstanceType": "$INSTANCE_TYPE", "InstanceCount": 1, "VolumeSizeInGB": 10},
    "StoppingCondition": {"MaxRuntimeInSeconds": $MAX_RUNTIME},
}, open(sys.argv[1], "w"))
PY

aws sagemaker create-training-job --cli-input-json "file://$STAGING/job.json" >/dev/null
aws sagemaker wait training-job-completed-or-stopped --training-job-name "$JOB_NAME" || true

STATUS=$(aws sagemaker describe-training-job --training-job-name "$JOB_NAME" --query TrainingJobStatus --output text)
if [[ "$STATUS" != "Completed" ]]; then
  echo "training job $STATUS" >&2
  aws sagemaker describe-training-job --training-job-name "$JOB_NAME" \
    --query '{Status:TrainingJobStatus,Reason:FailureReason}' --output json >&2
  echo "logs: aws logs tail /aws/sagemaker/TrainingJobs --log-stream-name-prefix $JOB_NAME" >&2
  exit 1
fi

MODEL_DATA=$(aws sagemaker describe-training-job --training-job-name "$JOB_NAME" \
  --query ModelArtifacts.S3ModelArtifacts --output text)
echo "    artifact: $MODEL_DATA"

echo "==> 4/4 registering as PendingManualApproval"
python3 - "$STAGING/package.json" <<PY
import json, sys
json.dump({
    "ModelPackageGroupName": "$GROUP",
    "ModelPackageDescription": "Refund risk, trained from $TRAINING_URI",
    "ModelApprovalStatus": "PendingManualApproval",
    "InferenceSpecification": {
        # Without these the container falls back to its default handler, whose
        # predict_fn returns a class label rather than a probability — which is
        # the entire point of a risk score.
        "Containers": [{
            "Image": "$IMAGE",
            "ModelDataUrl": "$MODEL_DATA",
            "Environment": {
                "SAGEMAKER_PROGRAM": "inference.py",
                "SAGEMAKER_SUBMIT_DIRECTORY": "$SOURCE_URI",
            },
        }],
        "SupportedContentTypes": ["text/csv", "application/json"],
        "SupportedResponseMIMETypes": ["text/csv", "application/json"],
    },
}, open(sys.argv[1], "w"))
PY

PACKAGE_ARN=$(aws sagemaker create-model-package --cli-input-json "file://$STAGING/package.json" \
  --query ModelPackageArn --output text)

cat <<MSG

Registered: $PACKAGE_ARN
  trained from : $TRAINING_URI
  artifact     : $MODEL_DATA

It is PendingManualApproval and deploys nowhere until approved (D-31). To
promote it:

  scripts/promote_model.sh "$PACKAGE_ARN"
MSG
