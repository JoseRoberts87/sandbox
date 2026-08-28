#!/usr/bin/env bash
#
# Check what is actually deployed and working, end to end.
#
#   scripts/verify.sh
#
# Every check runs — a failure does not stop the rest, because knowing which
# three things are broken beats knowing the first. Exits non-zero if any failed.
#
# Read-only. It queries and lists; it changes nothing.

set -uo pipefail

cd "$(dirname "$0")/.."

PASS=0; FAIL=0; SKIP=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; SKIP=$((SKIP+1)); }
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }
query() { scripts/redshift_query.sh "$1" 2>&1; }

# --------------------------------------------------------------------------
group "Infrastructure"

if ! RAW=$(tf_output raw_bucket_name); then
  bad "terraform outputs readable" "Is the stack applied, and are credentials valid?"
  echo; echo "Cannot continue without outputs."; exit 1
fi
ok "terraform outputs readable"

PROCESSED=$(tf_output processed_bucket_name)
SOURCE_NAME=$(tf_output etl_source_name)
DATASET=$(tf_output etl_dataset)
PREFIX="$SOURCE_NAME/$DATASET"

terraform -chdir=envs/dev plan -detailed-exitcode -input=false >/dev/null 2>&1
case $? in
  0) ok "no drift — deployed state matches the configuration" ;;
  2) bad "terraform plan reports changes" "Run: terraform -chdir=envs/dev plan" ;;
  *) skip "terraform plan" "could not run (credentials or backend)" ;;
esac

# --------------------------------------------------------------------------
group "Deployed code matches the working tree"

ARTIFACTS=$(tf_output artifacts_bucket_name)
DEPLOYED=$(aws s3 cp "s3://$ARTIFACTS/glue/scripts/raw_to_processed.py" - 2>/dev/null \
  | python3 -c 'import hashlib,sys; print(hashlib.md5(sys.stdin.buffer.read()).hexdigest())') || DEPLOYED=""
LOCAL=$(python3 -c 'import hashlib; print(hashlib.md5(open("glue/jobs/raw_to_processed.py","rb").read()).hexdigest())')

if [[ -z "$DEPLOYED" ]]; then
  skip "glue job script" "could not read it from the artifacts bucket"
elif [[ "$DEPLOYED" == "$LOCAL" ]]; then
  ok "glue job script matches the working tree"
else
  bad "deployed glue job script is stale" "Run: make apply — the job would run the previous version"
fi

group "Raw and processed zones"

if aws s3 ls "s3://$RAW/$PREFIX/" >/dev/null 2>&1 && \
   [[ -n "$(aws s3 ls "s3://$RAW/$PREFIX/" 2>/dev/null | grep -v '/$')" ]]; then
  ok "raw holds a file under $PREFIX/"
else
  bad "raw is empty at $PREFIX/" "Run: make land"
fi

PARTITIONS=$(aws s3 ls "s3://$PROCESSED/$PREFIX/" 2>/dev/null | grep -c 'ingest_date=')
if [[ "$PARTITIONS" -gt 0 ]]; then
  ok "processed has $PARTITIONS ingest_date partition(s)"
else
  bad "processed has no partitions" "Run: make etl"
fi

REJECTS=$(aws s3 ls "s3://$PROCESSED/_rejected/$PREFIX/" --recursive 2>/dev/null | wc -l | tr -d ' ')
if [[ "$REJECTS" == "0" ]]; then
  ok "no quarantined rows"
else
  bad "$REJECTS object(s) under _rejected/" "Inspect the reject_reason column before trusting the load"
fi

# --------------------------------------------------------------------------
group "Warehouse"

WG_STATUS=$(aws redshift-serverless get-workgroup \
  --workgroup-name "$(tf_output redshift_workgroup_name)" \
  --query workgroup.status --output text 2>/dev/null) || WG_STATUS=UNKNOWN

case "$WG_STATUS" in
  AVAILABLE) ok "workgroup is AVAILABLE" ;;
  CREATING|MODIFYING) bad "workgroup is $WG_STATUS" "Transient — wait and re-run. Queries fail with 'Redshift endpoint is not available' meanwhile" ;;
  *) bad "workgroup is $WG_STATUS" "Check the usage limit: it deactivates the workgroup on breach" ;;
esac

SCHEMAS=$(query "SELECT nspname FROM pg_namespace WHERE nspname IN ('landing','analytics','ml')")
if [[ "$SCHEMAS" == *landing* && "$SCHEMAS" == *analytics* && "$SCHEMAS" == *ml* ]]; then
  ok "schemas landing / analytics / ml exist"

  EXT=$(query "SELECT count(*) AS n FROM processed_ext.${SOURCE_NAME}_${DATASET}")
  if [[ "$EXT" == *"row"* && "$EXT" != *ERROR* ]]; then
    ok "Spectrum can read the processed Parquet through the Glue catalog"
  else
    bad "Spectrum cannot read processed_ext.${SOURCE_NAME}_${DATASET}" "$(echo "$EXT" | head -1)"
  fi

  COUNTS=$(query "SELECT
      (SELECT count(*) FROM landing.orders)   AS all_snapshots,
      (SELECT count(*) FROM analytics.orders) AS newest_only,
      (SELECT count(DISTINCT ingest_date) FROM landing.orders) AS snapshots")
  if [[ "$COUNTS" == *ERROR* ]]; then
    bad "could not read landing.orders" "$(echo "$COUNTS" | head -1)"
  else
    echo "$COUNTS" | sed 's/^/        /'
    ALL=$(echo "$COUNTS" | sed -n '3p' | awk '{print $1}')
    NEW=$(echo "$COUNTS" | sed -n '3p' | awk '{print $2}')
    SNAP=$(echo "$COUNTS" | sed -n '3p' | awk '{print $3}')

    [[ "$ALL" -gt 0 ]] && ok "warehouse holds rows" || bad "landing.orders is empty" "Run: make load"

    # The property the whole snapshot design rests on. Only testable once more
    # than one snapshot exists.
    if [[ "${SNAP:-0}" -gt 1 ]]; then
      if [[ "$NEW" -lt "$ALL" ]]; then
        ok "analytics.orders returns only the newest snapshot ($NEW of $ALL)"
      else
        bad "analytics.orders is not filtering to the newest snapshot" "Every partition is a full snapshot; this view must pin MAX(ingest_date)"
      fi
    else
      skip "snapshot filtering" "only one snapshot loaded; load a second date to test it"
    fi
  fi
else
  bad "schemas are missing" "Run: make migrate — terraform apply does not create schemas (D-38)"
  skip "Spectrum read" "needs schemas"
  skip "warehouse row counts" "needs schemas"
fi

# --------------------------------------------------------------------------
group "Model and endpoint"

GROUP_NAME=$(tf_output sagemaker_model_package_group)
VERSIONS=$(aws sagemaker list-model-packages --model-package-group-name "$GROUP_NAME" \
  --query 'length(ModelPackageSummaryList)' --output text 2>/dev/null)

if [[ "${VERSIONS:-0}" =~ ^[0-9]+$ && "${VERSIONS:-0}" -gt 0 ]]; then
  ok "$VERSIONS model version(s) registered"
else
  skip "registered model versions" "none yet — run: make train"
fi

if [[ "$(tf_output inference_enabled)" == "true" ]]; then
  ENDPOINT=$(tf_output endpoint_name)
  STATUS=$(aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT" \
    --query EndpointStatus --output text 2>/dev/null)
  [[ "$STATUS" == "InService" ]] && ok "endpoint $ENDPOINT is InService" \
                                 || bad "endpoint status is ${STATUS:-unknown}"
else
  skip "inference endpoint" "approved_model_package_arn is empty, so nothing is deployed — by design"
fi

# --------------------------------------------------------------------------
group "Cost guards"

NATS=$(aws ec2 describe-nat-gateways --filter Name=state,Values=available \
  --query 'length(NatGateways)' --output text 2>/dev/null)
[[ "${NATS:-0}" == "0" ]] && ok "no NAT gateways (D-37)" \
                          || bad "${NATS} NAT gateway(s) running" "These bill hourly, forever"

SCHEDULE=$(tf_output etl_schedule_state)
[[ "$SCHEDULE" == "DISABLED" ]] && ok "ETL schedule is disabled (Q-08 unanswered)" \
                                || bad "ETL schedule is $SCHEDULE"

WG_ARN=$(aws redshift-serverless get-workgroup \
  --workgroup-name "$(tf_output redshift_workgroup_name)" \
  --query workgroup.workgroupArn --output text 2>/dev/null)
if [[ -n "$WG_ARN" && "$WG_ARN" != "None" ]]; then
  LIMITS=$(aws redshift-serverless list-usage-limits --resource-arn "$WG_ARN" \
    --query 'length(usageLimits)' --output text 2>/dev/null)
  [[ "${LIMITS:-0}" -gt 0 ]] && ok "Redshift usage limit is set" \
                             || bad "no Redshift usage limit" "The only guard on unattended spend"
else
  skip "Redshift usage limit" "could not read the workgroup"
fi

# --------------------------------------------------------------------------
rule="────────────────────────────────────────────────────────────────"

if [[ "$FAIL" -eq 0 ]]; then
  printf '\n\033[32m%s\n' "$rule"
  printf '  HEALTHY — %d checks passed' "$PASS"
  [[ "$SKIP" -gt 0 ]] && printf ', %d skipped' "$SKIP"
  printf '\n\n'
  printf '  What is deployed matches the configuration, the data path holds,\n'
  printf '  and the cost guards are in place.\n'
  [[ "$SKIP" -gt 0 ]] && printf '  Skipped checks are noted above with the reason.\n'
  printf '%s\033[0m\n' "$rule"
  exit 0
fi

printf '\n\033[31m%s\n' "$rule" >&2
printf '  PROBLEMS FOUND — %d of %d checks failed\n\n' "$FAIL" "$((PASS + FAIL))" >&2
printf '  Each failing line above names the fix. Work down the list in\n' >&2
printf '  order: a stale deployment or a missing schema makes everything\n' >&2
printf '  after it fail too.\n' >&2
printf '%s\033[0m\n' "$rule" >&2
exit 1
