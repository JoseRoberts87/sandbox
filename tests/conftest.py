"""Shared fixtures.

The job script runs inside AWS Glue, where `awsglue` and `boto3` are provided by
the runtime. Neither is installed locally, so both are stubbed at import time.
Everything else — the Spark API the transform actually uses — is real, so these
tests exercise the deployed code rather than a copy of it.
"""

import importlib.util
import os
import subprocess
import sys
import time
import types
from pathlib import Path

import pytest

# Collecting a Spark TimestampType converts it to the *driver's* local timezone,
# so a developer in EDT and one in UTC would otherwise see different values for
# the same parse. Glue runs in UTC; match it here. Must happen before the JVM
# starts, which is why it is at import time rather than in a fixture.
os.environ["TZ"] = "UTC"
time.tzset()

ROOT = Path(__file__).resolve().parents[1]
JOB_PATH = ROOT / "glue" / "jobs" / "raw_to_processed.py"
DATA_PATH = ROOT / "data" / "dpe_interview_takehome_data.csv"


class GlueArgumentError(Exception):
    """Stand-in for the error awsglue raises when a required argument is absent."""


class GlueArgumentConflictError(Exception):
    """argparse.ArgumentError as raised by getResolvedOptions on a reserved name."""


# awsglue pre-registers these on its argparse parser whenever they appear in
# argv, and special-cases only JOB_NAME. Requesting JOB_ID or JOB_RUN_ID
# therefore raises "conflicting option string" and kills the run at startup.
# Reproduced here so the suite catches it — it did not, the first time.
_GLUE_RESERVED = ("JOB_ID", "JOB_RUN_ID")


def _get_resolved_options(args, options):
    """Close enough to awsglue.utils.getResolvedOptions to test argument handling."""
    resolved = {}

    for name in _GLUE_RESERVED:
        flag = f"--{name}"
        if flag in args:
            resolved[name] = args[args.index(flag) + 1]

    for option in options:
        flag = f"--{option}"
        if option in _GLUE_RESERVED and flag in args:
            raise GlueArgumentConflictError(
                f"argument {flag}: conflicting option string: {flag}"
            )
        if flag not in args:
            raise GlueArgumentError(f"argument --{option} is required")
        resolved[option] = args[args.index(flag) + 1]

    return resolved


def _install_glue_stubs():
    for name in (
        "awsglue",
        "awsglue.context",
        "awsglue.dynamicframe",
        "awsglue.job",
        "awsglue.utils",
        "boto3",
    ):
        sys.modules.setdefault(name, types.ModuleType(name))

    sys.modules["awsglue.context"].GlueContext = object
    sys.modules["awsglue.dynamicframe"].DynamicFrame = object
    sys.modules["awsglue.job"].Job = object
    sys.modules["awsglue.utils"].getResolvedOptions = _get_resolved_options
    sys.modules["boto3"].client = lambda *args, **kwargs: None


@pytest.fixture(scope="session")
def job():
    """The real job module, imported with its Glue-only dependencies stubbed."""
    _install_glue_stubs()
    module_spec = importlib.util.spec_from_file_location("raw_to_processed", JOB_PATH)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def orders_spec(job):
    return job.DATASET_SPECS["takehome/orders"]


@pytest.fixture(scope="session")
def sample_csv():
    if not DATA_PATH.exists():
        pytest.skip(f"sample data not present at {DATA_PATH}")
    return str(DATA_PATH)


def java_available():
    """macOS ships a /usr/bin/java shim that exists but fails without a JDK, so
    the binary has to actually run rather than merely be on PATH."""
    try:
        return subprocess.run(["java", "-version"], capture_output=True).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


@pytest.fixture(scope="session")
def spark(job):
    if not java_available():
        pytest.skip(
            "pyspark needs a JVM and no Java runtime was found. "
            "Install one with: brew install --cask temurin"
        )

    from pyspark.sql import SparkSession

    session = (
        SparkSession.builder.master("local[1]")
        .appName("raw_to_processed-tests")
        # Timestamps are compared against fixed values, so the session timezone
        # must not depend on the machine running the tests.
        .config("spark.sql.session.timeZone", "UTC")
        .config("spark.sql.shuffle.partitions", "1")
        .config("spark.ui.enabled", "false")
        .getOrCreate()
    )
    session.sparkContext.setLogLevel("ERROR")

    # Applied through the job's own function, so the tests cannot pass under a
    # configuration the deployed job does not use.
    job.configure_session(session)

    yield session
    session.stop()


@pytest.fixture
def make_raw(spark, orders_spec):
    """Build an all-strings DataFrame shaped like the raw CSV.

    Every row starts from a known-good baseline; each override changes only the
    fields under test, so a failure points at the rule rather than the fixture.
    """
    columns = [column["name"] for column in orders_spec["columns"]]
    baseline = {
        "order_id": "ORD-000001",
        "order_ts": "2025-06-01 10:00:00",
        "customer_id": "CUST-00001",
        "region": "EMEA",
        "channel": "retail",
        "product_sku": "SKU-1001",
        "product_name": "Widget",
        "category": "Puzzles",
        "quantity": "2",
        "unit_price_usd": "10.00",
        "discount_pct": "0.00",
        "order_status": "completed",
        "shipping_days": "3",
    }

    def _make(*overrides):
        rows = []
        for override in overrides or ({},):
            row = dict(baseline)
            row.update(override)
            rows.append(tuple(row[column] for column in columns))
        return spark.createDataFrame(rows, schema=columns)

    return _make
