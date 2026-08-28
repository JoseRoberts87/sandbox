#!/usr/bin/env bash
#
# Load one processed snapshot into Redshift.
#
#   scripts/load_warehouse.sh              # the newest partition in S3
#   scripts/load_warehouse.sh 2026-08-24   # a specific one
#
# Delete-then-insert on the partition, so re-running a date replaces it rather
# than duplicating (D-23). Requires the migrations to have been applied.

set -euo pipefail

cd "$(dirname "$0")/.."

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }

PROCESSED=$(tf_output processed_bucket_name) || {
  echo "error: could not read terraform outputs. Is the stack applied?" >&2; exit 1; }

SOURCE_NAME=$(tf_output etl_source_name)
DATASET=$(tf_output etl_dataset)

INGEST_DATE="${1:-}"

if [[ -z "$INGEST_DATE" ]]; then
  # Newest partition actually present, rather than assuming today — the ETL may
  # have last run on a different day.
  # Both `aws s3 ls` on a missing prefix and `grep` finding nothing exit 1, so
  # without the guard `set -e` would abort here and the message below — the one
  # that actually tells you what to do — could never print.
  INGEST_DATE=$(aws s3 ls "s3://$PROCESSED/$SOURCE_NAME/$DATASET/" 2>/dev/null \
    | grep -o 'ingest_date=[0-9][0-9-]*' | cut -d= -f2 | sort | tail -1) || INGEST_DATE=""

  if [[ -z "$INGEST_DATE" ]]; then
    echo "error: no ingest_date partitions under s3://$PROCESSED/$SOURCE_NAME/$DATASET/" >&2
    echo "Run the ETL first: make etl" >&2
    exit 1
  fi
  echo "newest partition: $INGEST_DATE"
fi

# The load names columns explicitly, so a processed zone written by an older
# version of the job fails on a column Redshift reports one at a time. Check the
# whole list up front and say what to do about it.
MISSING=$(scripts/redshift_query.sh "SELECT columnname FROM svv_external_columns
  WHERE schemaname = 'processed_ext' AND tablename = '${SOURCE_NAME}_${DATASET}'" 2>/dev/null \
  | python3 -c '
import re, sys
from pathlib import Path

present = {line.strip() for line in sys.stdin if re.fullmatch(r"[a-z_]+", line.strip())}
if not present:
    sys.exit(0)  # cannot tell; let the load report whatever is wrong

load = Path("sql/load_orders.sql").read_text()
select = re.search(r"\)\s*SELECT(.*?)FROM processed_ext", load, re.S).group(1)
needed = [c for c in re.findall(r"[a-z_]+", select) if c not in ("cast", "as", "date")]
print(",".join(c for c in needed if c not in present))
') || MISSING=""

if [[ -n "$MISSING" ]]; then
  cat >&2 <<MSG
error: the processed zone is missing columns the load expects:

  $MISSING

That means it was written by an older version of the Glue job. Deploy the
current one and rewrite the partition:

  make apply
  make etl
  make load
MSG
  exit 1
fi

scripts/redshift_sql.sh sql/load_orders.sql "ingest_date=$INGEST_DATE"

echo
scripts/redshift_query.sh "SELECT ingest_date, count(*) AS rows
  FROM landing.orders GROUP BY 1 ORDER BY 1"
