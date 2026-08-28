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

# Point terraform.tfvars at the approved version.
#
# This does not weaken D-31. The deployed version still lives in version control
# and still reaches the endpoint only through a reviewed diff and a manual
# apply — the script types the ARN instead of a person, which removes a class of
# paste error where a truncated or stale ARN silently deploys the wrong model.
TFVARS="envs/dev/terraform.tfvars"

if ! grep -qE '^[[:space:]]*approved_model_package_arn[[:space:]]*=' "$TFVARS"; then
  cat >&2 <<MSG
error: no approved_model_package_arn assignment in $TFVARS.

Add it by hand, then re-run:

    approved_model_package_arn = "$PACKAGE_ARN"
MSG
  exit 1
fi

CURRENT_ARN=$(grep -E '^[[:space:]]*approved_model_package_arn[[:space:]]*=' "$TFVARS" \
  | sed -E 's/.*"([^"]*)".*/\1/')

if [[ "$CURRENT_ARN" == "$PACKAGE_ARN" ]]; then
  echo "$TFVARS already points at this version."
else
  # `|` as the delimiter: an ARN contains slashes but never a pipe.
  sed -i.bak -E \
    "s|^([[:space:]]*approved_model_package_arn[[:space:]]*=[[:space:]]*).*|\1\"$PACKAGE_ARN\"|" \
    "$TFVARS"
  rm -f "$TFVARS.bak"

  echo "$TFVARS updated"
  echo "  was: ${CURRENT_ARN:-(empty)}"
  echo "  now: $PACKAGE_ARN"
  echo
  echo "The change, for review:"
  git --no-pager diff -- "$TFVARS" | sed 's/^/  /'
fi

cat <<MSG

Approved and recorded, but not yet served. Review the change above, then:

  make plan
  make apply

The first apply creates the endpoint, the Lambda proxy and the public API.
Later ones roll the endpoint onto the new version in place.
MSG
