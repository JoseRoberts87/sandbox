#!/usr/bin/env bash
#
# Delete the processed catalog table so the next ETL run recreates it.
#
#   scripts/reset_catalog_table.sh
#
# The Glue sink updates the catalog as it writes (--update_catalog=true), and
# adding a column that way is reliable. *Changing* a column's type is less so,
# and a stale type is the dangerous case: an epoch read as a timestamp, or a
# double read as a decimal, is silently wrong rather than an error.
#
# Deleting the table removes only metadata. The Parquet is untouched, and the
# next run re-registers the table and the partition it writes. Older partitions
# lose their registration, which costs nothing here — every partition is a full
# snapshot and only the newest is read (docs/data-layout.md).

set -euo pipefail

cd "$(dirname "$0")/.."

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }

DATABASE=$(tf_output glue_processed_database) || {
  echo "error: could not read terraform outputs. Is the stack applied?" >&2; exit 1; }

TABLE="$(tf_output etl_source_name)_$(tf_output etl_dataset)"

if aws glue get-table --database-name "$DATABASE" --name "$TABLE" >/dev/null 2>&1; then
  echo "deleting catalog table $DATABASE.$TABLE"
  aws glue delete-table --database-name "$DATABASE" --name "$TABLE"
  echo "  deleted — the next ETL run will recreate it from the current schema"
else
  echo "catalog table $DATABASE.$TABLE does not exist; nothing to delete"
fi
