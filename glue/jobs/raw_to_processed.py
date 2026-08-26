"""Glue ETL: one raw ingest_date partition -> partitioned Parquet in processed.

Layout on both sides (docs/data-layout.md, D-12):

    s3://<raw>/<source>/<dataset>/ingest_date=YYYY-MM-DD/<file>
    s3://<processed>/<source>/<dataset>/ingest_date=YYYY-MM-DD/*.parquet

A run is addressed by a single date, so a rerun of a date replaces that
partition instead of appending to it (D-19). Backfilling is the same code path
with a different --ingest_date, which is why job bookmarks are disabled: all
progress state is visible in S3 rather than hidden in the Glue service.

Job parameters (defaults come from the Terraform job definition; override per
run with `aws glue start-job-run --arguments`):

    --raw_bucket          source bucket
    --processed_bucket    destination bucket
    --processed_database  Glue catalog database for the processed table
    --source_name         first path segment, e.g. the system data came from
    --dataset             second path segment
    --source_format       csv | json | parquet          (default csv)
    --ingest_date         YYYY-MM-DD | latest | yesterday | today  (default latest)
    --required_columns    comma-separated; run fails if any are missing
    --update_catalog      true | false                  (default true)
    --allow_empty         true | false                  (default false)
    --csv_header          true | false                  (default true)
    --csv_infer_schema    true | false                  (default true)
"""

import re
import sys
from datetime import datetime, timedelta, timezone

import boto3
from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import StringType

REQUIRED_ARGS = [
    "JOB_NAME",
    "raw_bucket",
    "processed_bucket",
    "processed_database",
    "source_name",
    "dataset",
]

OPTIONAL_ARGS = {
    "JOB_RUN_ID": "unknown",
    "source_format": "csv",
    "ingest_date": "latest",
    "required_columns": "",
    "update_catalog": "true",
    "allow_empty": "false",
    "csv_header": "true",
    "csv_infer_schema": "true",
}

DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SUPPORTED_FORMATS = ("csv", "json", "parquet")


def log(message):
    """Prefixed so runs are greppable in CloudWatch."""
    print(f"[raw_to_processed] {message}")


def fail(message):
    """Fail closed (D-20): a bad run must not leave partial data downstream."""
    raise SystemExit(f"[raw_to_processed] FAILED: {message}")


def resolve_args():
    args = getResolvedOptions(sys.argv, REQUIRED_ARGS)

    supplied = [name for name in OPTIONAL_ARGS if f"--{name}" in sys.argv]
    if supplied:
        args.update(getResolvedOptions(sys.argv, supplied))

    for name, default in OPTIONAL_ARGS.items():
        if not args.get(name):
            args[name] = default

    return args


def as_bool(value):
    return str(value).strip().lower() in ("true", "yes", "1")


def latest_partition(bucket, prefix):
    """Newest ingest_date=* partition present under a dataset prefix."""
    paginator = boto3.client("s3").get_paginator("list_objects_v2")
    dates = []

    for page in paginator.paginate(Bucket=bucket, Prefix=prefix, Delimiter="/"):
        for entry in page.get("CommonPrefixes", []):
            segment = entry["Prefix"].rstrip("/").rsplit("/", 1)[-1]
            if segment.startswith("ingest_date="):
                value = segment.split("=", 1)[1]
                if DATE_PATTERN.match(value):
                    dates.append(value)

    if not dates:
        fail(f"no ingest_date=* partitions under s3://{bucket}/{prefix}")

    return max(dates)


def resolve_ingest_date(value, bucket, prefix):
    value = str(value).strip().lower()
    today = datetime.now(timezone.utc).date()

    if DATE_PATTERN.match(value):
        try:
            datetime.strptime(value, "%Y-%m-%d")
        except ValueError:
            fail(f"--ingest_date '{value}' is not a real date")
        return value

    if value == "latest":
        return latest_partition(bucket, prefix)
    if value == "yesterday":
        return (today - timedelta(days=1)).isoformat()
    if value == "today":
        return today.isoformat()

    fail(f"--ingest_date must be YYYY-MM-DD, latest, yesterday or today (got '{value}')")


def normalize(name):
    """Lowercase snake_case, safe for Glue/Athena column and table names."""
    cleaned = re.sub(r"[^0-9a-zA-Z]+", "_", str(name).strip()).strip("_").lower()
    if not cleaned:
        cleaned = "col"
    if cleaned[0].isdigit():
        cleaned = f"col_{cleaned}"
    return cleaned


def normalize_columns(columns):
    """Normalize, disambiguating names that collide after normalization."""
    counts, result = {}, []

    for column in columns:
        candidate = normalize(column)
        if candidate in counts:
            counts[candidate] += 1
            candidate = f"{candidate}_{counts[candidate]}"
        else:
            counts[candidate] = 0
        result.append(candidate)

    return result


def read_raw(spark, path, source_format, args):
    if source_format == "csv":
        return (
            spark.read.option("header", str(as_bool(args["csv_header"])).lower())
            .option("inferSchema", str(as_bool(args["csv_infer_schema"])).lower())
            .option("mode", "PERMISSIVE")
            .option("escape", '"')
            .csv(path)
        )
    if source_format == "json":
        return spark.read.json(path)
    return spark.read.parquet(path)


def main():
    args = resolve_args()

    source_format = args["source_format"].strip().lower()
    if source_format not in SUPPORTED_FORMATS:
        fail(f"--source_format must be one of {SUPPORTED_FORMATS} (got '{source_format}')")

    source_name = normalize(args["source_name"])
    dataset = normalize(args["dataset"])
    dataset_prefix = f"{source_name}/{dataset}/"

    ingest_date = resolve_ingest_date(args["ingest_date"], args["raw_bucket"], dataset_prefix)

    input_path = f"s3://{args['raw_bucket']}/{dataset_prefix}ingest_date={ingest_date}/"
    dataset_root = f"s3://{args['processed_bucket']}/{dataset_prefix}"
    output_partition = f"{dataset_root}ingest_date={ingest_date}/"
    table_name = f"{source_name}_{dataset}"

    log(f"reading  {input_path}")
    log(f"writing  {output_partition}")

    spark_context = SparkContext.getOrCreate()
    glue_context = GlueContext(spark_context)
    spark = glue_context.spark_session

    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    frame = read_raw(spark, input_path, source_format, args)
    frame = frame.toDF(*normalize_columns(frame.columns))

    row_count = frame.count()
    if row_count == 0 and not as_bool(args["allow_empty"]):
        fail(f"no rows found at {input_path}")

    required = [normalize(c) for c in args["required_columns"].split(",") if c.strip()]
    missing = [c for c in required if c not in frame.columns]
    if missing:
        fail(f"required columns missing from {input_path}: {missing}")

    # Trim strings, then stamp lineage so a processed row can be traced back to
    # the file and the job run that produced it.
    frame = frame.select(
        [
            F.trim(F.col(field.name)).alias(field.name)
            if isinstance(field.dataType, StringType)
            else F.col(field.name)
            for field in frame.schema.fields
        ]
    )
    frame = (
        frame.withColumn("etl_source_file", F.input_file_name())
        .withColumn("etl_processed_at", F.current_timestamp())
        .withColumn("etl_job_run_id", F.lit(args["JOB_RUN_ID"]))
        .withColumn("ingest_date", F.lit(ingest_date))
    )

    log(f"{row_count} rows, {len(frame.columns)} columns -> {table_name}")

    # Idempotency: clear this one partition, then write it. Only the target
    # partition is touched, so a rerun replaces rather than duplicates.
    log(f"purging {output_partition}")
    glue_context.purge_s3_path(output_partition, options={"retentionPeriod": 0})

    update_catalog = as_bool(args["update_catalog"])
    sink = glue_context.getSink(
        path=dataset_root,
        connection_type="s3",
        updateBehavior="UPDATE_IN_DATABASE" if update_catalog else "LOG",
        partitionKeys=["ingest_date"],
        enableUpdateCatalog=update_catalog,
        transformation_ctx="processed_sink",
    )
    if update_catalog:
        sink.setCatalogInfo(
            catalogDatabase=args["processed_database"],
            catalogTableName=table_name,
        )
    sink.setFormat("glueparquet", compression="snappy")
    sink.writeFrame(DynamicFrame.fromDF(frame, glue_context, "processed"))

    log(f"done: {row_count} rows written to {output_partition}")
    job.commit()


if __name__ == "__main__":
    main()
