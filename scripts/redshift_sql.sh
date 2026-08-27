#!/usr/bin/env bash
#
# Run SQL against Redshift Serverless through the Data API.
#
#   scripts/redshift_sql.sh sql/migrations                    # every file, in order
#   scripts/redshift_sql.sh sql/load_orders.sql ingest_date=2026-08-27
#
# Terraform owns infrastructure, not schema (D-38). DDL lives in sql/ as ordered,
# re-runnable files and is applied deliberately by a developer, same as apply.
#
# Placeholders of the form ${name} are substituted from terraform outputs and
# from any KEY=VALUE arguments. A file naming a placeholder that has no value is
# an error rather than a silently empty string.
#
# Each file's statements are sent as one batch, which the Data API runs as a
# single transaction — so a file either applies completely or not at all.

set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <file.sql|directory> [KEY=VALUE ...]" >&2
  exit 1
fi
shift

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }

# A workgroup that is CREATING or MODIFYING rejects statements with
# "Redshift endpoint is not available", which says nothing about waiting.
# Changing capacity or enhanced_vpc_routing puts it in MODIFYING for minutes.
wait_for_workgroup() {
  local name="$1" waited=0 status announced=0

  while true; do
    status=$(aws redshift-serverless get-workgroup --workgroup-name "$name" \
      --query workgroup.status --output text 2>/dev/null) || status=UNKNOWN

    case "$status" in
      AVAILABLE)
        [[ "$announced" -eq 1 ]] && echo "  workgroup available"
        return 0
        ;;
      CREATING|MODIFYING)
        if [[ "$announced" -eq 0 ]]; then
          echo "workgroup is $status — waiting up to 10 minutes"
          announced=1
        fi
        ;;
      *)
        cat >&2 <<MSG
error: workgroup $name is $status, not AVAILABLE.

If it was just modified, wait and retry. If queries were working and suddenly
are not, check the usage limit before assuming an outage — it is set to
deactivate the workgroup when the monthly RPU-hour allowance is breached:

  make verify
MSG
        return 1
        ;;
    esac

    waited=$((waited + 10))
    if [[ "$waited" -ge 600 ]]; then
      echo "error: workgroup still $status after 10 minutes" >&2
      return 1
    fi
    sleep 10
  done
}

if ! WORKGROUP=$(tf_output redshift_workgroup_name); then
  echo "error: could not read terraform outputs. Is phase 3 applied?" >&2
  exit 1
fi

wait_for_workgroup "$WORKGROUP" || exit 1

DATABASE=$(tf_output redshift_database_name)
SECRET_ARN=$(tf_output redshift_admin_secret_arn)
export SUB_redshift_role_arn="$(tf_output redshift_role_arn)"
export SUB_glue_database="$(tf_output glue_processed_database)"
export SUB_aws_region="$(tf_output region)"

for pair in "$@"; do
  [[ "$pair" == *=* ]] || { echo "error: expected KEY=VALUE, got '$pair'" >&2; exit 1; }
  export "SUB_${pair%%=*}=${pair#*=}"
done

if [[ -d "$TARGET" ]]; then
  mapfile -t FILES < <(find "$TARGET" -maxdepth 1 -name '*.sql' | sort)
else
  [[ -f "$TARGET" ]] || { echo "error: $TARGET not found" >&2; exit 1; }
  FILES=("$TARGET")
fi

# An empty match must not look like success. Without this, pointing the script
# at a directory holding no .sql files prints "done" having applied nothing.
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "error: no .sql files found in $TARGET" >&2
  exit 1
fi

echo "applying ${#FILES[@]} file(s) to $DATABASE on $WORKGROUP"

PAYLOAD=$(mktemp)
trap 'rm -f "$PAYLOAD"' EXIT

for file in "${FILES[@]}"; do
  echo "--- $file"

  python3 - "$file" "$WORKGROUP" "$DATABASE" "$SECRET_ARN" > "$PAYLOAD" <<'PY'
import json, os, re, sys

path, workgroup, database, secret_arn = sys.argv[1:5]
sql = open(path).read()

missing = set()
def substitute(match):
    name = match.group(1)
    value = os.environ.get(f"SUB_{name}")
    if value is None:
        missing.add(name)
        return match.group(0)
    return value

sql = re.sub(r"\$\{(\w+)\}", substitute, sql)
if missing:
    sys.exit(f"error: {path} needs values for: {', '.join(sorted(missing))}")

# Strip comment-only lines before splitting so a trailing comment does not
# become an empty statement.
lines = [ln for ln in sql.splitlines() if not ln.strip().startswith("--")]
statements = [s.strip() for s in "\n".join(lines).split(";") if s.strip()]
if not statements:
    sys.exit(f"error: {path} contains no statements")

json.dump({
    "WorkgroupName": workgroup,
    "Database": database,
    "SecretArn": secret_arn,
    "Sqls": statements,
}, sys.stdout)
PY

  STATEMENT_ID=$(aws redshift-data batch-execute-statement \
    --cli-input-json "file://$PAYLOAD" --query Id --output text)

  while true; do
    STATUS=$(aws redshift-data describe-statement --id "$STATEMENT_ID" --query Status --output text)
    case "$STATUS" in
      FINISHED) echo "    ok"; break ;;
      FAILED|ABORTED)
        echo "    $STATUS" >&2
        aws redshift-data describe-statement --id "$STATEMENT_ID" \
          --query '{Error:Error,Statements:SubStatements[].{Status:Status,Error:Error,Sql:QueryString}}' \
          --output json >&2
        exit 1
        ;;
      *) sleep 2 ;;
    esac
  done
done

echo "applied ${#FILES[@]} file(s)"
