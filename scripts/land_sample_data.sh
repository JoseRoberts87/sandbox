#!/usr/bin/env bash
#
# Land the sample dataset in the raw zone at the layout the ETL expects:
#
#   <source>/<dataset>/<file>
#
# Raw is flat: the job reads every file under the dataset prefix. The date lives
# on the *run* instead, as the ingest_date partition written to processed.
#
# The job resolves its input path from --source_name and --dataset, so the
# prefix here must match envs/dev/terraform.tfvars. See docs/data-layout.md.
#
# Usage: scripts/land_sample_data.sh

set -euo pipefail

FILE="data/dpe_interview_takehome_data.csv"

cd "$(dirname "$0")/.."

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }

if [[ ! -f "$FILE" ]]; then
  echo "error: $FILE not found" >&2
  exit 1
fi

if ! RAW_BUCKET=$(tf_output raw_bucket_name); then
  echo "error: could not read terraform outputs. Is the stack applied, and are AWS credentials valid?" >&2
  exit 1
fi

# From tfvars, so the landing path cannot drift from what the job reads.
SOURCE_NAME=$(tf_output etl_source_name)
DATASET=$(tf_output etl_dataset)

KEY="$SOURCE_NAME/$DATASET/$(basename "$FILE")"

echo "landing s3://$RAW_BUCKET/$KEY"
aws s3 cp "$FILE" "s3://$RAW_BUCKET/$KEY"

cat <<'MSG'

Done. Run the ETL over it with:

  aws glue start-job-run \
    --job-name "$(terraform -chdir=envs/dev output -raw glue_job_name)"

That reads every file under the dataset prefix and writes a snapshot to today's
ingest_date partition in processed. Pass --arguments '{"--ingest_date":"..."}'
to write a different partition, or "latest" to redo the most recent load.
MSG
