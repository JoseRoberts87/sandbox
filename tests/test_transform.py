"""Transform behaviour, exercised through real Spark.

These call `evaluate_rows` and `select_clean` — the same functions main() uses —
so they test the deployed logic rather than a reimplementation of it. They are
skipped when no JVM is available.
"""

from datetime import date, datetime
from decimal import Decimal

import pytest

pytestmark = pytest.mark.spark


def reasons(evaluated):
    return [row["reject_reason"] for row in evaluated.select("reject_reason").collect()]


def typed(evaluated, name):
    return evaluated.select(f"_typed_{name}").first()[0]


def evaluate(job, spec, frame):
    return job.evaluate_rows(frame, spec)


class TestAcceptance:
    def test_a_clean_row_is_accepted(self, job, orders_spec, make_raw):
        assert reasons(evaluate(job, orders_spec, make_raw())) == [""]


class TestTimestampParsing:
    @pytest.mark.parametrize(
        "raw,expected",
        [
            ("2026-01-28 16:29:16", datetime(2026, 1, 28, 16, 29, 16)),
            ("2025-05-06T07:42:56Z", datetime(2025, 5, 6, 7, 42, 56)),
            ("07/25/2025", datetime(2025, 7, 25, 0, 0, 0)),
            ("12-May-2025", datetime(2025, 5, 12, 0, 0, 0)),
        ],
    )
    def test_every_format_in_the_source_parses(self, job, orders_spec, make_raw, raw, expected):
        evaluated = evaluate(job, orders_spec, make_raw({"order_ts": raw}))
        assert typed(evaluated, "order_ts") == expected
        assert reasons(evaluated) == [""]

    def test_slash_dates_are_read_month_first(self, job, orders_spec, make_raw):
        # Documented assumption (T-2.16): 03/04 is March 4th, not April 3rd.
        evaluated = evaluate(job, orders_spec, make_raw({"order_ts": "03/04/2025"}))
        assert typed(evaluated, "order_ts") == datetime(2025, 3, 4, 0, 0, 0)

    def test_an_unparseable_timestamp_is_rejected_not_nulled(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"order_ts": "2025-13-45 99:99:99"}))
        assert typed(evaluated, "order_ts") is None
        assert "order_ts is not a valid epoch" in reasons(evaluated)[0]

    def test_a_future_order_is_rejected(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"order_ts": "2099-01-01 00:00:00"}))
        assert "order_ts is in the future" in reasons(evaluated)[0]


class TestNumericCleaning:
    def test_currency_symbol_is_stripped(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"unit_price_usd": "$159.28"}))
        assert typed(evaluated, "unit_price_usd") == pytest.approx(159.28)
        assert reasons(evaluated) == [""]

    def test_thousands_separator_is_stripped(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"unit_price_usd": "$1,234.56"}))
        assert typed(evaluated, "unit_price_usd") == pytest.approx(1234.56)

    def test_a_non_numeric_price_is_rejected_not_treated_as_missing(self, job, orders_spec, make_raw):
        """`money` cleaning strips every non-numeric character, so "free"
        collapses to an empty string and would otherwise be indistinguishable
        from an absent value — which now defaults to NaN and would pass."""
        evaluated = evaluate(job, orders_spec, make_raw({"unit_price_usd": "free"}))
        assert "unit_price_usd is not a valid double" in reasons(evaluated)[0]

    def test_a_missing_price_becomes_nan_and_is_kept(self, job, orders_spec, make_raw):
        import math

        evaluated = evaluate(job, orders_spec, make_raw({"unit_price_usd": ""}))
        assert math.isnan(typed(evaluated, "unit_price_usd"))
        assert reasons(evaluated) == [""]

    def test_a_missing_discount_becomes_nan_and_is_kept(self, job, orders_spec, make_raw):
        import math

        evaluated = evaluate(job, orders_spec, make_raw({"discount_pct": ""}))
        assert math.isnan(typed(evaluated, "discount_pct"))
        assert reasons(evaluated) == [""]

    def test_a_missing_quantity_becomes_null_and_is_kept(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"quantity": ""}))
        assert typed(evaluated, "quantity") is None
        assert reasons(evaluated) == [""]

    def test_a_blank_optional_number_becomes_null_and_is_kept(self, job, orders_spec, make_raw):
        # One row in the source file has no shipping_days. Absent is not invalid.
        evaluated = evaluate(job, orders_spec, make_raw({"shipping_days": ""}))
        assert typed(evaluated, "shipping_days") is None
        assert reasons(evaluated) == [""]


class TestStringCleaning:
    def test_whitespace_collapsed_and_region_mapped_to_the_canonical_form(
        self, job, orders_spec, make_raw
    ):
        # TR-01: the source mixes acronyms with a spelled-out name.
        evaluated = evaluate(job, orders_spec, make_raw({"region": "  NORTH   America "}))
        assert typed(evaluated, "region") == "namer"
        assert reasons(evaluated) == [""]

    def test_an_unknown_region_is_rejected(self, job, orders_spec, make_raw):
        # TR-02: region was the only dimension without a closed set.
        evaluated = evaluate(job, orders_spec, make_raw({"region": "atlantis"}))
        assert "region not in allowed values" in reasons(evaluated)[0]

    def test_enums_are_lowercased_and_trimmed(self, job, orders_spec, make_raw):
        # "  Puzzles " and "DIGITAL" both appear in the source file.
        assert typed(evaluate(job, orders_spec, make_raw({"category": "  Puzzles "})), "category") == "puzzles"
        assert typed(evaluate(job, orders_spec, make_raw({"channel": "RETAIL"})), "channel") == "retail"

    def test_free_text_is_lowercased_too(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"product_name": "  Deck   Box "}))
        assert typed(evaluated, "product_name") == "deck box"

    def test_identifiers_are_lowercased(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"order_id": " ORD-000001 "}))
        assert typed(evaluated, "order_id") == "ord-000001"

    def test_a_malformed_identifier_is_rejected(self, job, orders_spec, make_raw):
        # TR-06: insurance against a feed that changes shape.
        evaluated = evaluate(job, orders_spec, make_raw({"order_id": "not-an-order"}))
        assert "order_id is malformed" in reasons(evaluated)[0]


class TestRejectReasons:
    def test_a_missing_required_field_is_reported(self, job, orders_spec, make_raw):
        assert "order_id is missing" in reasons(evaluate(job, orders_spec, make_raw({"order_id": ""})))[0]

    def test_a_value_outside_the_allowed_set_is_reported(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"channel": "carrier-pigeon"}))
        assert "channel not in allowed values" in reasons(evaluated)[0]

    def test_below_minimum_is_reported(self, job, orders_spec, make_raw):
        assert "quantity below minimum 1" in reasons(evaluate(job, orders_spec, make_raw({"quantity": "0"})))[0]

    def test_above_maximum_is_reported(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"discount_pct": "3.5"}))
        assert "discount_pct above maximum 1" in reasons(evaluated)[0]

    def test_a_negative_price_is_reported(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"unit_price_usd": "-5.00"}))
        assert "unit_price_usd below minimum 0" in reasons(evaluated)[0]

    def test_every_problem_on_a_row_is_reported_not_just_the_first(self, job, orders_spec, make_raw):
        evaluated = evaluate(
            job,
            orders_spec,
            make_raw({"order_id": "", "channel": "smoke-signal", "quantity": "0"}),
        )
        reason = reasons(evaluated)[0]
        assert "order_id is missing" in reason
        assert "channel not in allowed values" in reason
        assert "quantity below minimum 1" in reason
        assert reason.count("; ") == 2


class TestDuplicatePrimaryKeys:
    def test_the_most_recent_row_wins_and_the_rest_are_quarantined(self, job, orders_spec, make_raw):
        frame = make_raw(
            {"order_id": "ORD-000900", "order_ts": "2025-06-01 10:00:00", "quantity": "1"},
            {"order_id": "ORD-000900", "order_ts": "2025-07-01 10:00:00", "quantity": "9"},
        )
        evaluated = evaluate(job, orders_spec, frame)
        by_quantity = {
            row["_typed_quantity"]: row["reject_reason"]
            for row in evaluated.select("_typed_quantity", "reject_reason").collect()
        }
        assert by_quantity[9] == ""
        assert "duplicate order_id" in by_quantity[1]

    def test_an_exact_duplicate_is_rejected_as_such(self, job, orders_spec, make_raw):
        """A row identical in every field carries no information and needs no
        adjudication. Calling it a key duplicate would hide that difference."""
        frame = make_raw({}, {})
        got = sorted(reasons(evaluate(job, orders_spec, frame)))
        assert got[0] == ""
        assert "exact duplicate" in got[1]

    def test_distinct_keys_are_untouched(self, job, orders_spec, make_raw):
        frame = make_raw({"order_id": "ORD-000001"}, {"order_id": "ORD-000002"})
        assert reasons(evaluate(job, orders_spec, frame)) == ["", ""]


class TestDerivedColumns:
    def _clean(self, job, spec, frame):
        return job.select_clean(job.evaluate_rows(frame, spec), spec).first()

    def test_amounts_apply_the_discount_to_the_line_total(self, job, orders_spec, make_raw):
        row = self._clean(
            job, orders_spec, make_raw({"quantity": "2", "unit_price_usd": "10.00", "discount_pct": "0.25"})
        )
        assert row["gross_amount_usd"] == Decimal("20.00")
        assert row["net_amount_usd"] == Decimal("15.00")

    def test_a_missing_discount_is_treated_as_zero(self, job, orders_spec, make_raw):
        row = self._clean(
            job, orders_spec, make_raw({"quantity": "3", "unit_price_usd": "5.00", "discount_pct": ""})
        )
        assert row["gross_amount_usd"] == row["net_amount_usd"] == Decimal("15.00")

    def test_order_date_is_the_date_part_of_the_timestamp(self, job, orders_spec, make_raw):
        row = self._clean(job, orders_spec, make_raw({"order_ts": "2025-06-01 10:00:00"}))
        assert row["order_date"] == date(2025, 6, 1)


class TestAgainstTheRealFile:
    @pytest.fixture
    def sample_frame(self, spark, job, sample_csv):
        frame = job.read_raw(
            spark, sample_csv, "csv", {"csv_header": "true", "csv_infer_schema": "false"}, True
        )
        return frame.toDF(*job.normalize_columns(frame.columns))

    def test_evaluates_every_row_and_explains_each_reject(self, job, orders_spec, sample_frame):
        """Asserts properties, not counts — the sample file changes size."""
        evaluated = job.evaluate_rows(sample_frame, orders_spec)
        assert evaluated.count() == sample_frame.count(), "rows must not be silently dropped"

        rejected = evaluated.filter("reject_reason != ''")
        # Every reject carries a reason. A blank one would be a row discarded
        # with no way to find out why.
        assert rejected.filter("reject_reason IS NULL OR reject_reason = ''").count() == 0

    def test_most_rows_survive_cleaning(self, job, orders_spec, sample_frame):
        """A wholesale rejection means the spec no longer matches the feed."""
        evaluated = job.evaluate_rows(sample_frame, orders_spec)
        total = evaluated.count()
        rejected = evaluated.filter("reject_reason != ''").count()
        assert rejected / total < 0.5, (
            f"{rejected}/{total} rejected — the spec and the data have diverged"
        )

    def test_dimensions_collapse_to_their_canonical_values(self, job, orders_spec, sample_frame):
        clean = job.select_clean(job.evaluate_rows(sample_frame, orders_spec), orders_spec)

        def distinct(column):
            return {row[column] for row in clean.select(column).distinct().collect()}

        # Subsets, not equality: which values appear depends on the file, but
        # cleaning must never produce a case or whitespace variant, and every
        # value must be inside its declared allowed-list.
        for column in ("region", "channel", "category", "order_status"):
            declared = next(
                c for c in orders_spec["columns"] if c["name"] == column
            ).get("allowed")
            if declared:
                assert distinct(column) <= set(declared) | {None}, column
            for value in distinct(column):
                if value is not None:
                    assert value == value.strip().lower(), f"{column}: {value!r}"

    def test_every_string_column_is_lowercased(self, job, orders_spec, sample_frame):
        clean = job.select_clean(job.evaluate_rows(sample_frame, orders_spec), orders_spec)
        text_columns = [
            c["name"] for c in orders_spec["columns"]
            if c["type"] == "string" and c.get("clean") == "text"
        ]
        condition = " OR ".join(f"({c} != lower({c}))" for c in text_columns)
        assert clean.filter(condition).count() == 0

    def test_currency_symbols_are_stripped_wherever_they_appear(
        self, job, orders_spec, sample_frame
    ):
        # Asserts the property over whatever the file contains, rather than
        # naming a row that may not survive the next replacement.
        raw_with_symbol = sample_frame.filter("unit_price_usd RLIKE '[^0-9.-]'")
        if raw_with_symbol.count() == 0:
            pytest.skip("no currency symbols in the current file")

        evaluated = job.evaluate_rows(raw_with_symbol, orders_spec)
        # These rows may fail for unrelated reasons; what matters is that the
        # currency symbol is never one of them.
        assert evaluated.filter("reject_reason LIKE '%unit_price_usd%'").count() == 0

        clean = job.select_clean(evaluated.filter("reject_reason = ''"), orders_spec)
        assert clean.filter("unit_price_usd IS NULL OR isnan(unit_price_usd)").count() == 0

    def test_a_blank_optional_number_survives_as_null(self, job, orders_spec, sample_frame):
        blank = sample_frame.filter("shipping_days IS NULL OR trim(shipping_days) = ''")
        if blank.count() == 0:
            pytest.skip("no blank shipping_days in the current file")

        evaluated = job.evaluate_rows(blank, orders_spec)
        # Absent is not invalid — no row may be rejected *because of*
        # shipping_days, whatever else is wrong with it.
        assert evaluated.filter("reject_reason LIKE '%shipping_days%'").count() == 0

        clean = job.select_clean(evaluated.filter("reject_reason = ''"), orders_spec)
        assert clean.filter("shipping_days IS NOT NULL").count() == 0

    def test_order_ts_is_an_epoch_that_round_trips(self, job, orders_spec, sample_frame):
        clean = job.select_clean(
            job.evaluate_rows(sample_frame, orders_spec).filter("reject_reason = ''"),
            orders_spec,
        )
        assert dict(clean.dtypes)["order_ts"] == "bigint"
        # The epoch and the derived date must describe the same instant.
        assert clean.filter("to_date(from_unixtime(order_ts)) != order_date").count() == 0
        # A date-only source value lands exactly at midnight UTC.
        assert clean.filter("order_ts % 86400 = 0").count() > 0

