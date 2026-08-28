"""Glue ETL: the raw dataset -> a partitioned Parquet snapshot in processed.

Layout (docs/data-layout.md, D-12):

    s3://<raw>/<source>/<dataset>/<file>
    s3://<processed>/<source>/<dataset>/ingest_date=YYYY-MM-DD/*.parquet

Raw is flat: a run reads every file under the dataset prefix. Processed is
partitioned by ingest_date, which is the date of the *run*, not a property of
the data.

That makes each processed partition a complete snapshot of raw as of that run,
so **consumers should read the newest ingest_date partition, not all of them** —
summing across partitions counts the same orders once per run.

Rerunning the same date is safe: the job purges that partition before rewriting
it (D-19), so a rerun replaces rather than appends. Job bookmarks are disabled,
which keeps all progress state visible in S3 rather than hidden in the Glue
service.

Two conventions worth knowing before reading the spec:

* **`order_ts` is stored as a Unix epoch in seconds, UTC.** The source carries
  four formats; the epoch removes the question of which one a row arrived in. A
  value with no time component lands at midnight UTC of that date.
* **Money is `double`, not `decimal`.** An absent price is required to be NaN,
  and decimal types cannot represent one. This trades exactness on monetary
  sums for that, and NaN propagates through any arithmetic it touches — which is
  why the derived amounts guard `discount_pct` with `nanvl`.

Datasets are declared in DATASET_SPECS below, keyed by "<source>/<dataset>".
A spec gives the column list, target types, cleaning rule per column, and the
constraints a row must satisfy. Nothing is inferred: CSV is read as all-strings
and cast deliberately, because inferSchema can choose different types for
different files of the same dataset.

Bad rows are quarantined rather than dropped or allowed through. Anything that
fails to parse or violates a constraint is written, with its reason and its
original untouched values, to:

    s3://<processed>/_rejected/<source>/<dataset>/ingest_date=YYYY-MM-DD/

The run then fails if the reject rate exceeds --max_reject_pct, so a single bad
row does not kill a batch but a broken feed does not load silently either
(D-20). Structural problems — a missing column, an unreadable path — still fail
the whole run immediately, because they mean the file is not what we think it is.

Job parameters (defaults come from the Terraform job definition; override per
run with `aws glue start-job-run --arguments`):

    --raw_bucket          source bucket
    --processed_bucket    destination bucket
    --processed_database  Glue catalog database for the processed table
    --source_name         first path segment, e.g. the system data came from
    --dataset             second path segment
    --source_format       csv | json | parquet          (default csv)
    --ingest_date         the partition this run writes:
                          YYYY-MM-DD | today | yesterday | latest  (default today)
                          `latest` reuses the newest partition already in
                          processed, i.e. redo the most recent load in place
    --max_reject_pct      fail the run above this percentage (default 5.0)
    --update_catalog      true | false                  (default true)
    --allow_empty         true | false                  (default false)
    --csv_header          true | false                  (default true)
    --csv_infer_schema    only used when the dataset has no spec (default false)
    --required_columns    extra required columns, comma-separated
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
from pyspark.sql.window import Window

# -----------------------------------------------------------------------------
# Dataset specifications
#
# cleaning rules:
#   text   trim, collapse internal whitespace, lowercase — every string column
#   money  trim, then strip currency symbols and thousands separators
#   trim   trim only — numerics and timestamps, which are cast, not cased
#
# Every rule trims. All text is lowercased, identifiers included: case carries no
# meaning in this feed, and a single convention removes a whole class of
# join-and-grouping bug where "EMEA" and "emea" are two values.
# -----------------------------------------------------------------------------

TAKEHOME_ORDERS = {
    "primary_key": "order_id",
    # When a primary key repeats, the most recent row wins.
    "dedup_order_by": "order_ts",
    # order_ts arrives in four different formats. Tried in order; first match
    # wins, and a value matching none of them is rejected rather than nulled.
    # Slash dates in this feed are unambiguously US month-first (every observed
    # value has a day > 12), which is the only reason MM/dd is safe to assume.
    "timestamp_formats": [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "MM/dd/yyyy",
        "dd-MMM-yyyy",
    ],
    "columns": [
        {
            "name": "order_id",
            "type": "string",
            "clean": "text",
            "required": True,
            "pattern": r"^ord-\d+$",
        },
        # Stored as a Unix epoch in seconds, UTC. The four source formats are
        # parsed to a timestamp first; a value with no time component lands at
        # midnight UTC of that date, which is what the parse already produces.
        {"name": "order_ts", "type": "epoch", "clean": "trim", "required": True},
        # Not required (TR-05): an order with an unknown customer is still a
        # real order with real revenue. `is_anonymous_customer` flags it.
        {
            "name": "customer_id",
            "type": "string",
            "clean": "text",
            "pattern": r"^cust-\d+$",
        },
        {
            "name": "region",
            "type": "string",
            "clean": "text",
            # TR-01: the source mixes acronyms with a spelled-out name. Mapped
            # to acronyms throughout, since that is the majority form.
            "map": {"north america": "namer"},
            # TR-02: closed set, so an unexpected region is quarantined rather
            # than loaded silently, as channel and order_status already are.
            "allowed": ["apac", "emea", "latam", "namer"],
        },
        {
            "name": "channel",
            "type": "string",
            "clean": "text",
            "allowed": ["online", "partner", "retail", "wholesale"],
        },
        # TR-03: opaque. One SKU maps to many product names and categories, so
        # this identifies nothing — not a join key, not a feature.
        {
            "name": "product_sku",
            "type": "string",
            "clean": "text",
            "required": True,
            "pattern": r"^sku-\d+$",
        },
        {"name": "product_name", "type": "string", "clean": "text"},
        {
            "name": "category",
            "type": "string",
            "clean": "text",
            "allowed": [
                "accessories",
                "board games",
                "digital",
                "miniatures",
                "puzzles",
                "trading cards",
            ],
        },
        # Missing becomes NULL rather than a reject. Values below 1 are still
        # quarantined: negatives appear evenly across every order status, which
        # reads as corruption rather than return lines (TR-04).
        {"name": "quantity", "type": "int", "clean": "trim", "min": 1},
        # double, not decimal, because a missing value must become NaN and
        # decimal types cannot represent it. See the note in the module
        # docstring — this costs exactness on money.
        {
            "name": "unit_price_usd",
            "type": "double",
            "clean": "money",
            "missing": "nan",
            "min": 0,
        },
        {
            "name": "discount_pct",
            "type": "double",
            "clean": "trim",
            "missing": "nan",
            "min": 0,
            "max": 1,
        },
        {
            "name": "order_status",
            "type": "string",
            "clean": "text",
            "allowed": ["cancelled", "completed", "pending", "refunded"],
        },
        # Nullable: an order that has not shipped has no value here.
        {"name": "shipping_days", "type": "int", "clean": "trim", "min": 0},
    ],
    # TR-07: an order cannot have been placed after the run that reads it.
    "reject_future": "order_ts",
    # Derived columns. Assumption: discount_pct is a fraction of the line total,
    # so net = quantity * unit_price * (1 - discount_pct).
    "derived": {
        "order_date": "to_date(order_ts)",
        "order_year": "year(order_ts)",
        "order_month": "month(order_ts)",
        "order_dow": "dayofweek(order_ts) - 1",
        # `coalesce` handles NULL but not NaN, and an absent discount is NaN
        # here — without `nanvl` a missing discount would turn every derived
        # amount into NaN. An absent *price* is left to propagate, because an
        # amount computed from an unknown price is genuinely unknown.
        "gross_amount_usd": "round(quantity * unit_price_usd, 2)",
        "net_amount_usd": (
            "round(quantity * unit_price_usd * (1 - coalesce(nanvl(discount_pct, 0), 0)), 2)"
        ),
        "discount_amount_usd": (
            "round(quantity * unit_price_usd * coalesce(nanvl(discount_pct, 0), 0), 2)"
        ),
        "is_discounted": "coalesce(nanvl(discount_pct, 0), 0) > 0",
        "is_digital": "category = 'digital'",
        "is_anonymous_customer": "customer_id IS NULL",
    },
    # Window-derived, so it cannot live in `derived` above.
    "sequence": {
        "name": "customer_order_seq",
        "partition_by": "customer_id",
        "order_by": "order_ts",
    },
}

DATASET_SPECS = {
    "takehome/orders": TAKEHOME_ORDERS,
}

REQUIRED_ARGS = [
    "JOB_NAME",
    "raw_bucket",
    "processed_bucket",
    "processed_database",
    "source_name",
    "dataset",
]

# Reserved by Glue: awsglue.getResolvedOptions registers these itself whenever
# they appear in argv, and only special-cases JOB_NAME. Asking it to resolve
# JOB_ID or JOB_RUN_ID re-adds an argument argparse already has, which fails the
# run before it starts with "conflicting option string". Read them from argv.
RESERVED_ARGS = ("JOB_ID", "JOB_RUN_ID")

OPTIONAL_ARGS = {
    "source_format": "csv",
    "ingest_date": "today",
    "required_columns": "",
    "max_reject_pct": "5.0",
    "update_catalog": "true",
    "allow_empty": "false",
    "csv_header": "true",
    "csv_infer_schema": "false",
}

DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SUPPORTED_FORMATS = ("csv", "json", "parquet")
REJECTED_ROOT = "_rejected"


def log(message):
    """Prefixed so runs are greppable in CloudWatch."""
    print(f"[raw_to_processed] {message}")


def fail(message):
    """Structural failure: the input is not what we think it is (D-20)."""
    raise SystemExit(f"[raw_to_processed] FAILED: {message}")


def argv_value(name, default=None):
    """Read `--name value` straight from argv, for arguments getResolvedOptions
    refuses to resolve."""
    flag = f"--{name}"
    if flag in sys.argv:
        index = sys.argv.index(flag) + 1
        if index < len(sys.argv) and not sys.argv[index].startswith("--"):
            return sys.argv[index]
    return default


def resolve_args():
    args = getResolvedOptions(sys.argv, REQUIRED_ARGS)

    supplied = [name for name in OPTIONAL_ARGS if f"--{name}" in sys.argv]
    if supplied:
        args.update(getResolvedOptions(sys.argv, supplied))

    for name, default in OPTIONAL_ARGS.items():
        if not args.get(name):
            args[name] = default

    # Glue may already have surfaced these; fall back to argv, then to a marker
    # so lineage columns are never null.
    for name in RESERVED_ARGS:
        if not args.get(name):
            args[name] = argv_value(name, "unknown")

    return args


def as_bool(value):
    return str(value).strip().lower() in ("true", "yes", "1")


def latest_partition(bucket, prefix):
    """Newest ingest_date=* partition present under a dataset prefix.

    Raw is unpartitioned, so this is asked of the processed zone: it answers
    "which partition did the last run write", for redoing that load in place.
    """
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
    """Resolve the partition this run writes. `bucket` is the processed bucket,
    consulted only for `latest`."""
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


def configure_session(spark):
    """Apply the Spark settings this transform's contract depends on.

    ANSI mode makes a failed cast or an unparseable timestamp *throw*, which
    would abort an entire batch because of one bad value. Everything here
    depends on the opposite: a bad value becomes NULL, is detected, and is
    quarantined with a reason. Multi-format timestamp parsing needs it too,
    since coalescing across formats evaluates every branch and all but one of
    them will fail by design.

    Spark 3.5 (Glue 5.0) defaults this off and Spark 4 defaults it on, so it is
    set explicitly rather than inherited from whichever runtime we land on.

    The session timezone is pinned for the same reason. Rows are bucketed into
    ingest_date partitions and carry a derived order_date; under a non-UTC
    session both can land a day out, and the layout convention says UTC
    (docs/data-layout.md).
    """
    spark.conf.set("spark.sql.ansi.enabled", "false")
    spark.conf.set("spark.sql.session.timeZone", "UTC")
    return spark


def read_raw(spark, path, source_format, args, has_spec):
    if source_format == "csv":
        # A spec means the types are declared, so never infer them.
        infer = "false" if has_spec else str(as_bool(args["csv_infer_schema"])).lower()
        return (
            spark.read.option("header", str(as_bool(args["csv_header"])).lower())
            .option("inferSchema", infer)
            .option("mode", "PERMISSIVE")
            .option("escape", '"')
            .csv(path)
        )
    if source_format == "json":
        return spark.read.json(path)
    return spark.read.parquet(path)


def clean_expression(column, rule):
    """Cleaning applied before casting. Blank strings become NULL throughout."""
    value = F.trim(F.col(column))

    if rule == "money":
        # Currency symbols, thousands separators, stray spaces.
        value = F.regexp_replace(value, r"[^0-9.\-]", "")
    elif rule == "text":
        value = F.lower(F.trim(F.regexp_replace(value, r"\s+", " ")))

    return F.when(value == "", None).otherwise(value)


def typed_frame(frame, spec):
    """Add a cleaned, cast copy of every declared column as `_typed_<name>`.

    An `epoch` column is held as a timestamp here so the derived expressions can
    use date functions on it; `select_clean` converts it to seconds on the way
    out.
    """
    for column in spec["columns"]:
        name = column["name"]
        cleaned = clean_expression(name, column.get("clean", "trim"))

        if column["type"] in ("timestamp", "epoch"):
            # First format that parses wins. A value with no time component
            # lands at midnight of that date, in the session timezone (UTC).
            value = F.coalesce(
                *[F.to_timestamp(cleaned, fmt) for fmt in spec["timestamp_formats"]]
            )
        elif column["type"] == "string":
            value = cleaned
            # Canonicalise before the allowed-list is checked, or the mapping
            # would be judged against values it is meant to replace.
            for source, target in column.get("map", {}).items():
                value = F.when(value == source, F.lit(target)).otherwise(value)
        else:
            value = cleaned.cast(column["type"])
            # A missing number becomes NaN where asked, NULL otherwise. NaN is
            # only representable in float and double.
            if column.get("missing") == "nan":
                value = F.when(value.isNull(), F.lit(float("nan"))).otherwise(value)

        frame = frame.withColumn(f"_typed_{name}", value)

    return frame


def reject_reason_expression(spec, extra_required):
    """One string per row: every reason it is unfit, or '' if it is fine."""
    checks = []

    for column in spec["columns"]:
        name = column["name"]
        raw, typed = F.col(name), F.col(f"_typed_{name}")
        required = column.get("required", False) or name in extra_required

        if required:
            checks.append(F.when(raw.isNull() | (F.trim(raw) == ""), F.lit(f"{name} is missing")))

        # Present in the file but unparseable: the value is wrong, not absent.
        # A NaN default means "absent", so it must not read as unparseable.
        unparsed = typed.isNull() if column.get("missing") != "nan" else F.isnan(typed)
        checks.append(
            F.when(
                raw.isNotNull() & (F.trim(raw) != "") & unparsed,
                F.concat(F.lit(f"{name} is not a valid {column['type']}: "), F.trim(raw)),
            )
        )

        if "pattern" in column:
            checks.append(
                F.when(
                    typed.isNotNull() & ~typed.rlike(column["pattern"]),
                    F.concat(F.lit(f"{name} is malformed: "), typed),
                )
            )

        if "allowed" in column:
            checks.append(
                F.when(
                    typed.isNotNull() & ~typed.isin(column["allowed"]),
                    F.concat(F.lit(f"{name} not in allowed values: "), typed),
                )
            )

        # NaN means absent here, so it must not trip a bounds check.
        real = typed.isNotNull() if column.get("missing") != "nan" else ~F.isnan(typed)

        if "min" in column:
            checks.append(
                F.when(
                    real & (typed < F.lit(column["min"])),
                    F.lit(f"{name} below minimum {column['min']}"),
                )
            )

        if "max" in column:
            checks.append(
                F.when(
                    real & (typed > F.lit(column["max"])),
                    F.lit(f"{name} above maximum {column['max']}"),
                )
            )

    future_column = spec.get("reject_future")
    if future_column:
        checks.append(
            F.when(
                F.col(f"_typed_{future_column}") > F.current_timestamp(),
                F.lit(f"{future_column} is in the future"),
            )
        )

    # concat_ws drops NULLs, so unfired checks contribute nothing.
    return F.concat_ws("; ", *checks)


def evaluate_rows(frame, spec, extra_required=()):
    """Add a `_typed_<name>` column per declared column, plus `reject_reason`.

    `reject_reason` is '' for rows that are fit to load and a `; `-joined list of
    every problem otherwise. Nothing is filtered here — the caller decides what
    to do with each side.
    """
    evaluated = typed_frame(frame, spec).withColumn(
        "reject_reason", reject_reason_expression(spec, list(extra_required))
    )

    # Exact duplicates first, and separately from key duplicates. A row that
    # repeats in every field carries no information and needs no adjudication;
    # a repeated key with differing values is a genuine conflict, and calling
    # the first kind "duplicate order_id" would hide that difference.
    source_columns = [column["name"] for column in spec["columns"]]
    exact_window = Window.partitionBy(*source_columns).orderBy(F.lit(1))
    evaluated = evaluated.withColumn("_exact_row", F.row_number().over(exact_window))
    evaluated = evaluated.withColumn(
        "reject_reason",
        F.when(
            (F.col("_exact_row") > 1) & (F.col("reject_reason") == ""),
            F.lit("exact duplicate of an earlier row"),
        ).otherwise(F.col("reject_reason")),
    ).drop("_exact_row")

    # Duplicate primary keys: keep the most recent, quarantine the rest. Which
    # row is correct is a source-system question, so nothing is silently merged.
    primary_key = spec.get("primary_key")
    if primary_key:
        dedup_column = spec.get("dedup_order_by")
        ordering = (
            F.col(f"_typed_{dedup_column}").desc_nulls_last()
            if dedup_column
            else F.col(f"_typed_{primary_key}").asc()
        )
        window = Window.partitionBy(f"_typed_{primary_key}").orderBy(ordering)
        evaluated = evaluated.withColumn("_row_number", F.row_number().over(window))
        evaluated = evaluated.withColumn(
            "reject_reason",
            F.when(
                (F.col("_row_number") > 1) & (F.col("reject_reason") == ""),
                F.lit(f"duplicate {primary_key}, superseded by a later row"),
            ).otherwise(F.col("reject_reason")),
        ).drop("_row_number")

    return evaluated


def select_clean(evaluated, spec):
    """Typed columns under their final names, plus the spec's derived columns.

    Derived expressions are evaluated while `epoch` columns are still
    timestamps, so they can use date functions; the conversion to seconds
    happens last.
    """
    clean = evaluated.select(
        [F.col(f"_typed_{column['name']}").alias(column["name"]) for column in spec["columns"]]
    )

    for name, expression in spec.get("derived", {}).items():
        clean = clean.withColumn(name, F.expr(expression))

    sequence = spec.get("sequence")
    if sequence:
        # Nth order for this customer. Only meaningful within one snapshot: the
        # history is whatever the current file holds.
        window = Window.partitionBy(sequence["partition_by"]).orderBy(sequence["order_by"])
        clean = clean.withColumn(sequence["name"], F.row_number().over(window))
        # An anonymous customer has no sequence to belong to.
        clean = clean.withColumn(
            sequence["name"],
            F.when(F.col(sequence["partition_by"]).isNull(), None).otherwise(
                F.col(sequence["name"])
            ),
        )

    for column in spec["columns"]:
        if column["type"] == "epoch":
            clean = clean.withColumn(
                column["name"], F.unix_timestamp(F.col(column["name"])).cast("long")
            )

    return clean


def write_partition(glue_context, frame, path, dataset_root, database, table, update_catalog):
    """Purge the target partition, then write it. Reruns replace, not append."""
    log(f"purging {path}")
    glue_context.purge_s3_path(path, options={"retentionPeriod": 0})

    sink = glue_context.getSink(
        path=dataset_root,
        connection_type="s3",
        updateBehavior="UPDATE_IN_DATABASE" if update_catalog else "LOG",
        partitionKeys=["ingest_date"],
        enableUpdateCatalog=update_catalog,
        transformation_ctx=f"sink_{table}",
    )
    if update_catalog:
        sink.setCatalogInfo(catalogDatabase=database, catalogTableName=table)
    sink.setFormat("glueparquet", compression="snappy")
    sink.writeFrame(DynamicFrame.fromDF(frame, glue_context, table))


def add_lineage(frame, ingest_date, job_run_id):
    return (
        frame.withColumn("etl_source_file", F.input_file_name())
        .withColumn("etl_processed_at", F.current_timestamp())
        .withColumn("etl_job_run_id", F.lit(job_run_id))
        .withColumn("ingest_date", F.lit(ingest_date))
    )


def main():
    args = resolve_args()

    source_format = args["source_format"].strip().lower()
    if source_format not in SUPPORTED_FORMATS:
        fail(f"--source_format must be one of {SUPPORTED_FORMATS} (got '{source_format}')")

    source_name = normalize(args["source_name"])
    dataset = normalize(args["dataset"])
    dataset_prefix = f"{source_name}/{dataset}/"
    spec = DATASET_SPECS.get(f"{source_name}/{dataset}")

    ingest_date = resolve_ingest_date(args["ingest_date"], args["processed_bucket"], dataset_prefix)

    input_path = f"s3://{args['raw_bucket']}/{dataset_prefix}"
    dataset_root = f"s3://{args['processed_bucket']}/{dataset_prefix}"
    output_partition = f"{dataset_root}ingest_date={ingest_date}/"
    rejected_root = f"s3://{args['processed_bucket']}/{REJECTED_ROOT}/{dataset_prefix}"
    rejected_partition = f"{rejected_root}ingest_date={ingest_date}/"
    table_name = f"{source_name}_{dataset}"

    log(f"reading  {input_path}")
    log(f"writing  {output_partition}")
    log(f"spec     {'declared' if spec else 'none — generic passthrough'}")

    spark_context = SparkContext.getOrCreate()
    glue_context = GlueContext(spark_context)
    spark = configure_session(glue_context.spark_session)

    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    frame = read_raw(spark, input_path, source_format, args, spec is not None)
    frame = frame.toDF(*normalize_columns(frame.columns))

    total_rows = frame.count()
    if total_rows == 0 and not as_bool(args["allow_empty"]):
        fail(f"no rows found at {input_path}")

    extra_required = [normalize(c) for c in args["required_columns"].split(",") if c.strip()]
    expected = [c["name"] for c in spec["columns"]] if spec else []
    missing = [c for c in expected + extra_required if c not in frame.columns]
    if missing:
        fail(f"columns missing from {input_path}: {missing}")

    update_catalog = as_bool(args["update_catalog"])

    if not spec:
        # No declared schema: trim strings and pass through unchanged.
        frame = frame.select(
            [
                F.trim(F.col(f.name)).alias(f.name)
                if isinstance(f.dataType, StringType)
                else F.col(f.name)
                for f in frame.schema.fields
            ]
        )
        frame = add_lineage(frame, ingest_date, args["JOB_RUN_ID"])
        log(f"{total_rows} rows, {len(frame.columns)} columns -> {table_name}")
        write_partition(
            glue_context,
            frame,
            output_partition,
            dataset_root,
            args["processed_database"],
            table_name,
            update_catalog,
        )
        log(f"done: {total_rows} rows written to {output_partition}")
        job.commit()
        return

    raw_columns = [c["name"] for c in spec["columns"]]
    evaluated = evaluate_rows(frame, spec, extra_required)
    evaluated.cache()
    rejected = evaluated.filter(F.col("reject_reason") != "")
    accepted = evaluated.filter(F.col("reject_reason") == "")

    rejected_rows = rejected.count()
    accepted_rows = total_rows - rejected_rows
    reject_pct = (rejected_rows / total_rows * 100) if total_rows else 0.0
    log(f"{total_rows} rows: {accepted_rows} accepted, {rejected_rows} rejected ({reject_pct:.1f}%)")

    # Rejects are written before any threshold check, so a failed run still
    # leaves the evidence needed to diagnose it.
    if rejected_rows:
        for row in rejected.select("reject_reason").limit(20).collect():
            log(f"  reject: {row['reject_reason']}")
        write_partition(
            glue_context,
            add_lineage(
                rejected.select(*raw_columns, "reject_reason"), ingest_date, args["JOB_RUN_ID"]
            ),
            rejected_partition,
            rejected_root,
            args["processed_database"],
            f"{table_name}_rejected",
            update_catalog,
        )
        log(f"rejects written to {rejected_partition}")
    else:
        # Clear rejects left by an earlier run of this date. Without this, a
        # rerun after fixing the source would leave stale rejects behind.
        glue_context.purge_s3_path(rejected_partition, options={"retentionPeriod": 0})

    max_reject_pct = float(args["max_reject_pct"])
    if reject_pct > max_reject_pct:
        fail(
            f"reject rate {reject_pct:.1f}% exceeds --max_reject_pct {max_reject_pct}. "
            f"Rejected rows and reasons are at {rejected_partition}"
        )

    clean = select_clean(accepted, spec)

    clean = add_lineage(clean, ingest_date, args["JOB_RUN_ID"])
    log(f"{accepted_rows} rows, {len(clean.columns)} columns -> {table_name}")

    write_partition(
        glue_context,
        clean,
        output_partition,
        dataset_root,
        args["processed_database"],
        table_name,
        update_catalog,
    )

    log(f"done: {accepted_rows} rows written to {output_partition}")
    job.commit()


if __name__ == "__main__":
    main()
