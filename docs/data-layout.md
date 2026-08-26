# Data layout

**Decided (D-12).** Every dataset in the raw and processed zones uses the same
prefix layout:

```
<source>/<dataset>/ingest_date=YYYY-MM-DD/<file>
```

Both zones share it so a partition can be addressed by one date in either
bucket, and the ETL job's input and output paths differ only by bucket name.

## Segments

| Segment | Meaning | Rules |
|---|---|---|
| `<source>` | The system the data came from — a vendor, an application, an export process | lowercase, `snake_case`, stable over time |
| `<dataset>` | The specific feed within that source | lowercase, `snake_case` |
| `ingest_date=YYYY-MM-DD` | The UTC date the data **landed**, not the date the events occurred | zero-padded ISO date, always UTC |
| `<file>` | Original filename in raw; Parquet part files in processed | unchanged in raw |

Names must be lowercase `snake_case` because Glue and Athena lowercase
identifiers; a `Sales Data/` prefix becomes an awkward table name and a source of
case-sensitivity bugs. The ETL job normalizes both path segments and column
names on the way through, but the prefixes should be correct at the source.

## Why `ingest_date=` in the path

- **Hive-style partitioning.** `key=value` is the format Glue, Athena, Spark and
  Redshift Spectrum all recognize automatically. The date becomes a queryable
  column without being stored in every row.
- **Partition pruning.** A query filtered on `ingest_date` reads only that
  prefix. Without it, every query scans every file ever landed — the difference
  between scanning one day and scanning the whole history.
- **Addressable reruns.** One date identifies exactly one unit of work, which is
  what makes the ETL idempotent (see below).

## Zones

### Raw — `s3://<project>-<env>-raw-<suffix>/`

Files land exactly as received and are **never modified in place**. Original
format, original filename, original content. Versioned, and nothing expires:
everything downstream is regenerable from this bucket, so it is the only copy
that must not be lost.

```
s3://sandbox-dev-raw-data-platform/
└── acme_crm/
    └── customers/
        ├── ingest_date=2026-08-24/customers_20260824.csv
        └── ingest_date=2026-08-25/customers_20260825.csv
```

### Processed — `s3://<project>-<env>-processed-<suffix>/`

Same prefix layout, Snappy-compressed Parquet, written only by the Glue job.
Not versioned — it is rebuildable from raw, so keeping superseded versions of a
rewritten partition is not worth the storage.

```
s3://sandbox-dev-processed-data-platform/
└── acme_crm/
    └── customers/
        ├── ingest_date=2026-08-24/part-00000-....snappy.parquet
        └── ingest_date=2026-08-25/part-00000-....snappy.parquet
```

Each row carries lineage columns added by the job:

| Column | Meaning |
|---|---|
| `ingest_date` | Partition key, projected from the path |
| `etl_source_file` | The raw file this row came from |
| `etl_processed_at` | When the job wrote it |
| `etl_job_run_id` | The Glue job run that produced it |

### Artifacts — `s3://<project>-<env>-artifacts-<suffix>/`

Not a data zone. Fixed prefixes:

| Prefix | Contents | Lifecycle |
|---|---|---|
| `glue/scripts/` | Job scripts, uploaded by Terraform | versioned, kept |
| `glue/temp/` | Glue shuffle and staging | expires after 7 days |
| `glue/spark-logs/` | Spark event logs for the Spark UI | expires after 7 days |
| `training/` | Versioned training sets (phase 4) | versioned, kept |
| `models/` | Model artifacts (phase 4) | versioned, kept |

## Landing a file

```bash
RAW=$(terraform -chdir=envs/dev output -raw raw_bucket_name)

aws s3 cp ./customers_20260825.csv \
  "s3://$RAW/acme_crm/customers/ingest_date=2026-08-25/customers_20260825.csv"
```

## Reprocessing

The Glue job takes `--ingest_date` and rewrites exactly that partition: it
purges the processed prefix for that date, then writes it again. Rerunning a
date is safe and produces the same result, so a backfill is the same code path
as a normal run:

```bash
aws glue start-job-run \
  --job-name "$(terraform -chdir=envs/dev output -raw glue_job_name)" \
  --arguments '{"--ingest_date":"2026-08-24"}'
```

This is why job bookmarks are disabled (a revision to D-19): the partition
layout already identifies what has and has not been processed, in a place we can
inspect, rather than in service-side state that can drift from what is in S3.

## Conventions to hold to

- One dataset per `<source>/<dataset>/` prefix. Do not mix schemas under one.
- Never write to the processed zone by hand — it is job output, and a manual
  file will be silently deleted the next time that partition is rewritten.
- Never modify a file in raw. Correcting data means landing a new file under a
  new `ingest_date` and reprocessing.
- `ingest_date` is always UTC, to avoid a partition that shifts with daylight
  saving.

## Open

**Event date vs. ingest date.** `ingest_date` records arrival. If the data
carries its own event timestamp and queries filter on *that*, the processed zone
may need a second partition key (or to be partitioned on event date instead).
That cannot be settled until we know the schema — see Q-01, Q-02, and the note
in D-12. Raw stays partitioned by arrival date regardless: it records what
happened, not what the data says.
