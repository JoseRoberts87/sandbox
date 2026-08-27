#!/usr/bin/env bash
#
# Run one SELECT against Redshift and print the rows.
#
#   scripts/redshift_query.sh "SELECT count(*) FROM analytics.orders"
#
# redshift_sql.sh applies files and reports success or failure; this is for
# looking at data. Read-only by convention, not enforced — it is a thin wrapper
# over the Data API.

set -euo pipefail

cd "$(dirname "$0")/.."

SQL="${1:-}"
[[ -n "$SQL" ]] || { echo "usage: $0 \"<sql>\"" >&2; exit 1; }

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }

WORKGROUP=$(tf_output redshift_workgroup_name) || {
  echo "error: could not read terraform outputs. Is phase 3 applied?" >&2; exit 1; }

ID=$(aws redshift-data execute-statement \
  --workgroup-name "$WORKGROUP" \
  --database "$(tf_output redshift_database_name)" \
  --secret-arn "$(tf_output redshift_admin_secret_arn)" \
  --sql "$SQL" --query Id --output text)

while true; do
  STATUS=$(aws redshift-data describe-statement --id "$ID" --query Status --output text)
  case "$STATUS" in
    FINISHED) break ;;
    FAILED|ABORTED)
      aws redshift-data describe-statement --id "$ID" --query Error --output text >&2
      exit 1 ;;
    *) sleep 1 ;;
  esac
done

# HasResultSet is false for DDL/DML; only fetch when there is something to show.
if [[ "$(aws redshift-data describe-statement --id "$ID" --query HasResultSet --output text)" != "True" ]]; then
  echo "(no result set)"
  exit 0
fi

aws redshift-data get-statement-result --id "$ID" --output json | python3 -c '
import json, sys
result = json.load(sys.stdin)
columns = [c["name"] for c in result["ColumnMetadata"]]

def cell(value):
    if value.get("isNull"):
        return "NULL"
    return str(next(iter(value.values())))

rows = [[cell(v) for v in row] for row in result.get("Records", [])]
widths = [max(len(c), *(len(r[i]) for r in rows)) if rows else len(c)
          for i, c in enumerate(columns)]

print("  ".join(c.ljust(w) for c, w in zip(columns, widths)))
print("  ".join("-" * w for w in widths))
for row in rows:
    print("  ".join(v.ljust(w) for v, w in zip(row, widths)))
print(f"\n({len(rows)} row{"" if len(rows) == 1 else "s"})")
'
