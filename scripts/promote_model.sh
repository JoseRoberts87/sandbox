#!/usr/bin/env bash
#
# Approve a model version in the registry (D-31).
#
#   scripts/promote_model.sh                 # the newest pending version
#   scripts/promote_model.sh <package-arn>   # a specific one
#
# Approving marks a version fit to serve. It deploys nothing on its own: the
# endpoint follows `approved_model_package_arn` in terraform.tfvars, so serving
# it is a separate, reviewed change. This script prints the line to paste.

set -euo pipefail

cd "$(dirname "$0")/.."

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }

PACKAGE_ARN="${1:-}"

if [[ -z "$PACKAGE_ARN" ]]; then
  GROUP=$(tf_output sagemaker_model_package_group) || {
    echo "error: could not read terraform outputs. Is phase 4 applied?" >&2; exit 1; }

  PACKAGE_ARN=$(aws sagemaker list-model-packages \
    --model-package-group-name "$GROUP" \
    --model-approval-status PendingManualApproval \
    --sort-by CreationTime --sort-order Descending \
    --max-results 1 --query 'ModelPackageSummaryList[0].ModelPackageArn' --output text) || PACKAGE_ARN=""

  if [[ -z "$PACKAGE_ARN" || "$PACKAGE_ARN" == "None" ]]; then
    echo "error: no PendingManualApproval versions in $GROUP. Run scripts/train_model.sh first." >&2
    exit 1
  fi
fi

echo "Reviewing $PACKAGE_ARN"
aws sagemaker describe-model-package --model-package-name "$PACKAGE_ARN" \
  --query '{Status:ModelApprovalStatus,Created:CreationTime,Description:ModelPackageDescription}' \
  --output table

CURRENT=$(aws sagemaker describe-model-package --model-package-name "$PACKAGE_ARN" \
  --query ModelApprovalStatus --output text)

if [[ "$CURRENT" == "Approved" ]]; then
  echo "Already approved."
else
  read -r -p "Approve this version? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "Left as $CURRENT."; exit 0; }

  aws sagemaker update-model-package \
    --model-package-arn "$PACKAGE_ARN" --model-approval-status Approved >/dev/null
  echo "Approved."
fi

cat <<MSG

Approved, but not yet served. To deploy it, set this in
envs/dev/terraform.tfvars and apply:

  approved_model_package_arn = "$PACKAGE_ARN"

  terraform -chdir=envs/dev plan
  terraform -chdir=envs/dev apply

The first apply creates the endpoint, the Lambda proxy and the public API.
Later ones roll the endpoint onto the new version in place.
MSG
