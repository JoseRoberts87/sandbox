#!/usr/bin/env bash
#
# Start the Glue ETL job and wait for it to finish.
#
#   scripts/run_etl.sh                    # write today's snapshot
#   scripts/run_etl.sh 2026-08-24         # write a specific partition
#   scripts/run_etl.sh latest             # redo the most recent load in place
#
# A run reads every file under the raw dataset prefix and writes a complete
# snapshot to one ingest_date partition (docs/data-layout.md). Rerunning a date
# replaces that partition rather than appending.

set -euo pipefail

cd "$(dirname "$0")/.."

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }

JOB=$(tf_output glue_job_name) || {
  echo "error: could not read terraform outputs. Is the stack applied?" >&2; exit 1; }

# Is the deployed script the one in the working tree?
#
# Terraform uploads the job script on apply. Editing it and running the job
# without applying runs the *previous* version, and the symptom appears much
# later and somewhere else — a downstream schema that does not match, or a fix
# that appears not to have worked. Cheap to check, so check.
ARTIFACTS=$(tf_output artifacts_bucket_name)
SCRIPT_KEY="glue/scripts/raw_to_processed.py"

DEPLOYED_HASH=$(aws s3 cp "s3://$ARTIFACTS/$SCRIPT_KEY" - 2>/dev/null \
  | python3 -c 'import hashlib,sys; print(hashlib.md5(sys.stdin.buffer.read()).hexdigest())') \
  || DEPLOYED_HASH=""
LOCAL_HASH=$(python3 -c 'import hashlib; print(hashlib.md5(open("glue/jobs/raw_to_processed.py","rb").read()).hexdigest())')

if [[ -z "$DEPLOYED_HASH" ]]; then
  echo "warning: could not read the deployed job script; running anyway" >&2
elif [[ "$DEPLOYED_HASH" != "$LOCAL_HASH" ]]; then
  cat >&2 <<MSG
error: the deployed job script differs from glue/jobs/raw_to_processed.py.

  deployed: $DEPLOYED_HASH
  local:    $LOCAL_HASH

Running now would execute the previous version, and the symptom would surface
later and somewhere else. Deploy the current one first:

  make apply
MSG
  exit 1
fi

INGEST_DATE="${1:-}"
ARGS=()
if [[ -n "$INGEST_DATE" ]]; then
  ARGS=(--arguments "{\"--ingest_date\":\"$INGEST_DATE\"}")
  echo "starting $JOB for ingest_date=$INGEST_DATE"
else
  echo "starting $JOB (today's partition)"
fi

RUN_ID=$(aws glue start-job-run --job-name "$JOB" "${ARGS[@]}" --query JobRunId --output text)
echo "run: $RUN_ID"

# Glue has no waiter for job runs, so poll. Runs here take a couple of minutes;
# most of that is Spark starting up rather than the transform itself.
POLL_ERRORS=0

while true; do
  if ! STATE=$(aws glue get-job-run --job-name "$JOB" --run-id "$RUN_ID" \
    --query JobRun.JobRunState --output text 2>/dev/null); then
    # A blip reading the job state must not abandon a job that is running fine.
    POLL_ERRORS=$((POLL_ERRORS + 1))
    if [[ "$POLL_ERRORS" -ge 5 ]]; then
      echo "error: could not read state of run $RUN_ID after $POLL_ERRORS attempts" >&2
      exit 1
    fi
    sleep 10
    continue
  fi
  POLL_ERRORS=0

  case "$STATE" in
    SUCCEEDED)
      echo "  SUCCEEDED"
      break
      ;;
    FAILED|ERROR|TIMEOUT|STOPPED)
      echo "  $STATE" >&2
      aws glue get-job-run --job-name "$JOB" --run-id "$RUN_ID" \
        --query 'JobRun.{State:JobRunState,Error:ErrorMessage}' --output json >&2
      cat >&2 <<MSG

Full driver output:
  aws logs tail /aws-glue/jobs/output --log-stream-name-prefix $RUN_ID

The job's own messages are prefixed [raw_to_processed]; anything it rejected is
under _rejected/ in the processed bucket with a reject_reason column.
MSG
      exit 1
      ;;
    *)
      printf '  %s\r' "$STATE"
      sleep 10
      ;;
  esac
done

PROCESSED=$(tf_output processed_bucket_name)
SOURCE_NAME=$(tf_output etl_source_name)
DATASET=$(tf_output etl_dataset)

echo
echo "processed partitions:"
aws s3 ls "s3://$PROCESSED/$SOURCE_NAME/$DATASET/" | sed 's/^/  /'

# `aws s3 ls` exits 1 when the prefix does not exist, which is exactly what a
# clean run looks like. Under `set -e` that would fail the script on success.
REJECTS=$(aws s3 ls "s3://$PROCESSED/_rejected/$SOURCE_NAME/$DATASET/" --recursive 2>/dev/null | wc -l | tr -d ' ') || REJECTS=0
if [[ "$REJECTS" != "0" ]]; then
  echo
  echo "WARNING: $REJECTS rejected object(s) under _rejected/$SOURCE_NAME/$DATASET/."
  echo "The run passed the reject-rate threshold, but some rows were quarantined."
fi
