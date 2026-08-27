# Data layout

**Decided (D-12).** The two zones are laid out differently, on purpose:

```
raw        <source>/<dataset>/<file>
processed  <source>/<dataset>/ingest_date=YYYY-MM-DD/*.parquet
```

**Raw is flat.** A file is landed under its dataset prefix and that is all; there
is no date in the path. A job run reads every file under the prefix.

**Processed is partitioned by `ingest_date`** — the UTC date of the *run*, not a
property of the data. Since each run reprocesses the whole of raw, a partition is
a complete snapshot of the dataset as of that run.

> **Consumers should read the newest `ingest_date` partition, not all of them.**
> Every partition contains the full dataset, so summing across partitions counts
> the same rows once per run.

## Segments

| Segment | Meaning | Rules |
|---|---|---|
| `<source>` | The system the data came from — a vendor, an application, an export process | lowercase, `snake_case`, stable over time |
| `<dataset>` | The specific feed within that source | lowercase, `snake_case` |
| `<file>` | Original filename in raw | unchanged |
| `ingest_date=YYYY-MM-DD` | *Processed only.* The UTC date of the run that wrote the partition | zero-padded ISO date, always UTC |

Names must be lowercase `snake_case` because Glue and Athena lowercase
identifiers; a `Sales Data/` prefix becomes an awkward table name and a source of
case-sensitivity bugs. The ETL job normalizes both path segments and column
names on the way through, but the prefixes should be correct at the source.

## Why `ingest_date=` on the processed side

- **Hive-style partitioning.** `key=value` is the format Glue, Athena, Spark and
  Redshift Spectrum all recognize automatically. The date becomes a queryable
  column without being stored in every row.
- **Partition pruning.** A query filtered on `ingest_date` reads only that
  prefix, so reading the current snapshot does not scan every past one.
- **Idempotent reruns.** One date identifies exactly one unit of output, which is
  what lets the job purge and rewrite a partition rather than appending to it.

Raw gets none of this because it holds one small, whole dataset. If a real feed
later delivers dated drops, raw should be partitioned too and this decision
revisited — see Q-01.

## Zones

### Raw — `s3://<project>-<env>-raw-<suffix>/`

Files land exactly as received and are **never modified in place**. Original
format, original filename, original content. Versioned, and nothing expires:
everything downstream is regenerable from this bucket, so it is the only copy
that must not be lost.

```
s3://sandbox-dev-raw-data-platform/
└── takehome/
    └── orders/
        └── dpe_interview_takehome_data.csv
```

Landing a corrected file means replacing the object — bucket versioning keeps the
previous copy — and rerunning the job.

### Processed — `s3://<project>-<env>-processed-<suffix>/`

Same prefix layout, Snappy-compressed Parquet, written only by the Glue job.
Not versioned — it is rebuildable from raw, so keeping superseded versions of a
rewritten partition is not worth the storage.

```
s3://sandbox-dev-processed-data-platform/
└── takehome/
    └── orders/
        ├── ingest_date=2026-08-26/part-00000-....snappy.parquet   <- snapshot
        └── ingest_date=2026-08-27/part-00000-....snappy.parquet   <- current
```

Each row carries lineage columns added by the job:

| Column | Meaning |
|---|---|
| `ingest_date` | Partition key, projected from the path — the date of the run |
| `etl_source_file` | The raw file this row came from |
| `etl_processed_at` | When the job wrote it |
| `etl_job_run_id` | The Glue job run that produced it |

#### Rejected rows

Rows the ETL could not parse or that violated a constraint are quarantined under
a reserved top-level prefix in the same bucket, never mixed in with clean data:

```
s3://<project>-<env>-processed-<suffix>/_rejected/<source>/<dataset>/ingest_date=YYYY-MM-DD/
```

Each row keeps its original untouched values and gains a `reject_reason` column.
The prefix is partitioned and rewritten exactly like the clean data, so rerunning
a date clears that date's rejects — including when the rerun produces none.

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

aws s3 cp ./dpe_interview_takehome_data.csv \
  "s3://$RAW/takehome/orders/dpe_interview_takehome_data.csv"
```

For the sample dataset, `scripts/land_sample_data.sh` does exactly this.

## Reprocessing

`--ingest_date` names the partition a run *writes*. The job purges that partition
before writing it, so rerunning the same date replaces the snapshot rather than
appending to it:

```bash
JOB=$(terraform -chdir=envs/dev output -raw glue_job_name)

# write today's snapshot (the default)
aws glue start-job-run --job-name "$JOB"

# redo the most recent load in place, whatever date it was
aws glue start-job-run --job-name "$JOB" --arguments '{"--ingest_date":"latest"}'

# write a specific partition
aws glue start-job-run --job-name "$JOB" --arguments '{"--ingest_date":"2026-08-24"}'
```

Because raw is flat, running on a *new* date produces another full snapshot
rather than an increment. Use `latest` when the intent is "reload what is there",
and the default when the intent is "take today's snapshot".

This is also why job bookmarks are disabled (a revision to D-19): what has been
processed is visible in S3 as partitions we can inspect, rather than in
service-side state that can drift.

## Conventions to hold to

- One dataset per `<source>/<dataset>/` prefix. Do not mix schemas under one.
- Never write to the processed zone by hand — it is job output, and a manual
  file will be silently deleted the next time that partition is rewritten.
- Never edit a file in raw in place. Correcting data means uploading a replacement
  object — versioning keeps the old one — and rerunning the job.
- `ingest_date` is always UTC, to avoid a partition that shifts with daylight
  saving.

## Open

**Snapshot partitions vs. event date.** `ingest_date` records when a run
happened, so every partition holds the whole dataset. Once the data is queried in
anger, partitioning processed on `order_date` — which the orders dataset already
derives — would suit real queries better and would make partitions additive
rather than repeated. That is the open half of D-12; it is worth settling before
Redshift loads in phase 3, since it changes what a COPY should read.
