"""Pure-Python helpers: no Spark, no AWS."""

from datetime import datetime, timedelta, timezone

import pytest

from conftest import GlueArgumentConflictError, GlueArgumentError


class TestNormalize:
    @pytest.mark.parametrize(
        "raw,expected",
        [
            ("  Order ID  ", "order_id"),
            ("Order-ID", "order_id"),
            ("unit_price_usd", "unit_price_usd"),
            ("total ($)", "total"),
            ("Trading Cards", "trading_cards"),
            ("a...b", "a_b"),
            ("", "col"),
            ("   ", "col"),
            ("!!!", "col"),
        ],
    )
    def test_produces_athena_safe_names(self, job, raw, expected):
        assert job.normalize(raw) == expected

    def test_prefixes_names_starting_with_a_digit(self, job):
        # Glue and Athena reject identifiers that begin with a number.
        assert job.normalize("2024 sales") == "col_2024_sales"

    def test_disambiguates_collisions(self, job):
        # Without this, two source headers could silently become one column.
        assert job.normalize_columns(["Order ID", "order_id", "ORDER-ID"]) == [
            "order_id",
            "order_id_1",
            "order_id_2",
        ]

    def test_leaves_distinct_names_alone(self, job):
        assert job.normalize_columns(["a", "b"]) == ["a", "b"]


class TestAsBool:
    @pytest.mark.parametrize("value", ["true", "TRUE", "True", "yes", "1", " true "])
    def test_truthy(self, job, value):
        assert job.as_bool(value) is True

    @pytest.mark.parametrize("value", ["false", "no", "0", "", "maybe", None])
    def test_falsy(self, job, value):
        assert job.as_bool(value) is False


class TestResolveIngestDate:
    def test_explicit_date_passes_through(self, job):
        assert job.resolve_ingest_date("2026-08-24", "bucket", "prefix/") == "2026-08-24"

    def test_yesterday_and_today_are_utc(self, job):
        today = datetime.now(timezone.utc).date()
        assert job.resolve_ingest_date("today", "b", "p/") == today.isoformat()
        assert (
            job.resolve_ingest_date("yesterday", "b", "p/")
            == (today - timedelta(days=1)).isoformat()
        )

    def test_case_and_whitespace_tolerated(self, job):
        today = datetime.now(timezone.utc).date().isoformat()
        assert job.resolve_ingest_date("  TODAY  ", "b", "p/") == today

    @pytest.mark.parametrize("value", ["2025-13-01", "2025-02-30"])
    def test_impossible_dates_fail(self, job, value):
        # Shape-valid but not a real date — must not reach S3 as a prefix.
        with pytest.raises(SystemExit):
            job.resolve_ingest_date(value, "b", "p/")

    @pytest.mark.parametrize("value", ["tomorrow", "24-08-2026", "", "last-week"])
    def test_unrecognised_values_fail(self, job, value):
        with pytest.raises(SystemExit):
            job.resolve_ingest_date(value, "b", "p/")


class _FakePaginator:
    def __init__(self, pages):
        self._pages = pages

    def paginate(self, **_):
        return self._pages


class _FakeS3:
    def __init__(self, pages):
        self._pages = pages

    def get_paginator(self, _):
        return _FakePaginator(self._pages)


def _prefixes(*names):
    return [{"CommonPrefixes": [{"Prefix": f"takehome/orders/{n}/"} for n in names]}]


class TestLatestPartition:
    def test_picks_the_newest_partition(self, job, monkeypatch):
        pages = _prefixes("ingest_date=2026-08-24", "ingest_date=2026-08-26", "ingest_date=2026-08-25")
        monkeypatch.setattr(job.boto3, "client", lambda *_, **__: _FakeS3(pages))
        assert job.latest_partition("bucket", "takehome/orders/") == "2026-08-26"

    def test_ignores_unrelated_and_malformed_prefixes(self, job, monkeypatch):
        pages = _prefixes("ingest_date=2026-08-24", "_temporary", "ingest_date=not-a-date")
        monkeypatch.setattr(job.boto3, "client", lambda *_, **__: _FakeS3(pages))
        assert job.latest_partition("bucket", "takehome/orders/") == "2026-08-24"

    def test_no_partitions_is_a_failure_not_an_empty_run(self, job, monkeypatch):
        monkeypatch.setattr(job.boto3, "client", lambda *_, **__: _FakeS3([{}]))
        with pytest.raises(SystemExit):
            job.latest_partition("bucket", "takehome/orders/")

    def test_resolve_ingest_date_delegates_for_latest(self, job, monkeypatch):
        pages = _prefixes("ingest_date=2026-01-01", "ingest_date=2026-03-01")
        monkeypatch.setattr(job.boto3, "client", lambda *_, **__: _FakeS3(pages))
        assert job.resolve_ingest_date("latest", "bucket", "takehome/orders/") == "2026-03-01"


REQUIRED = {
    "JOB_NAME": "job",
    "raw_bucket": "raw",
    "processed_bucket": "processed",
    "processed_database": "db",
    "source_name": "takehome",
    "dataset": "orders",
}


def _argv(**extra):
    argv = ["raw_to_processed.py"]
    for key, value in {**REQUIRED, **extra}.items():
        argv += [f"--{key}", value]
    return argv


class TestResolveArgs:
    def test_applies_defaults_for_omitted_options(self, job, monkeypatch):
        monkeypatch.setattr(job.sys, "argv", _argv())
        args = job.resolve_args()
        assert args["source_format"] == "csv"
        assert args["ingest_date"] == "today"
        assert args["max_reject_pct"] == "5.0"
        assert args["csv_infer_schema"] == "false"

    def test_explicit_values_win(self, job, monkeypatch):
        monkeypatch.setattr(job.sys, "argv", _argv(ingest_date="2026-01-01", max_reject_pct="0"))
        args = job.resolve_args()
        assert args["ingest_date"] == "2026-01-01"
        assert args["max_reject_pct"] == "0"

    def test_blank_value_falls_back_to_the_default(self, job, monkeypatch):
        # Terraform can pass an empty string for an unset argument.
        monkeypatch.setattr(job.sys, "argv", _argv(source_format=""))
        assert job.resolve_args()["source_format"] == "csv"

    def test_job_run_id_in_argv_does_not_break_resolution(self, job, monkeypatch):
        """Regression: Glue always passes --JOB_RUN_ID, and asking
        getResolvedOptions to resolve it raises `conflicting option string`,
        which killed the run before main() did anything."""
        monkeypatch.setattr(job.sys, "argv", _argv(JOB_RUN_ID="jr_abc123", JOB_ID="j_xyz"))
        args = job.resolve_args()
        assert args["JOB_RUN_ID"] == "jr_abc123"

    def test_reserved_arguments_are_never_requested(self, job):
        # Requesting one of these from getResolvedOptions is the bug above.
        for name in job.RESERVED_ARGS:
            assert name not in job.OPTIONAL_ARGS
            assert name not in job.REQUIRED_ARGS

    def test_requesting_a_reserved_argument_would_conflict(self, job, monkeypatch):
        # Pins the awsglue behaviour the fix works around.
        argv = _argv(JOB_RUN_ID="jr_abc123")
        with pytest.raises(GlueArgumentConflictError):
            job.getResolvedOptions(argv, ["JOB_RUN_ID"])

    def test_job_run_id_falls_back_when_absent(self, job, monkeypatch):
        monkeypatch.setattr(job.sys, "argv", _argv())
        assert job.resolve_args()["JOB_RUN_ID"] == "unknown"

    def test_argv_value_reads_a_flag_directly(self, job, monkeypatch):
        monkeypatch.setattr(job.sys, "argv", ["x", "--foo", "bar", "--empty", "", "--flagonly"])
        assert job.argv_value("foo") == "bar"
        assert job.argv_value("empty") == ""
        assert job.argv_value("flagonly", "fallback") == "fallback"
        assert job.argv_value("absent", "fallback") == "fallback"

    def test_missing_required_argument_is_an_error(self, job, monkeypatch):
        argv = _argv()
        index = argv.index("--raw_bucket")
        monkeypatch.setattr(job.sys, "argv", argv[:index] + argv[index + 2 :])
        with pytest.raises(GlueArgumentError):
            job.resolve_args()
