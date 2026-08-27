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
        assert "order_ts is not a valid timestamp" in reasons(evaluated)[0]


class TestNumericCleaning:
    def test_currency_symbol_is_stripped(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"unit_price_usd": "$159.28"}))
        assert typed(evaluated, "unit_price_usd") == Decimal("159.28")
        assert reasons(evaluated) == [""]

    def test_thousands_separator_is_stripped(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"unit_price_usd": "$1,234.56"}))
        assert typed(evaluated, "unit_price_usd") == Decimal("1234.56")

    def test_a_non_numeric_price_is_rejected(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"unit_price_usd": "free"}))
        assert typed(evaluated, "unit_price_usd") is None
        assert "unit_price_usd is not a valid decimal(12,2)" in reasons(evaluated)[0]

    def test_a_blank_optional_number_becomes_null_and_is_kept(self, job, orders_spec, make_raw):
        # One row in the source file has no shipping_days. Absent is not invalid.
        evaluated = evaluate(job, orders_spec, make_raw({"shipping_days": ""}))
        assert typed(evaluated, "shipping_days") is None
        assert reasons(evaluated) == [""]


class TestStringCleaning:
    def test_codes_are_uppercased_and_whitespace_collapsed(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"region": "  north   america "}))
        assert typed(evaluated, "region") == "NORTH AMERICA"

    def test_enums_are_lowercased_and_trimmed(self, job, orders_spec, make_raw):
        # "  Puzzles " and "DIGITAL" both appear in the source file.
        assert typed(evaluate(job, orders_spec, make_raw({"category": "  Puzzles "})), "category") == "puzzles"
        assert typed(evaluate(job, orders_spec, make_raw({"channel": "RETAIL"})), "channel") == "retail"

    def test_free_text_keeps_its_case(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"product_name": "  Deck   Box "}))
        assert typed(evaluated, "product_name") == "Deck Box"

    def test_identifiers_are_uppercased(self, job, orders_spec, make_raw):
        evaluated = evaluate(job, orders_spec, make_raw({"order_id": " ord-000001 "}))
        assert typed(evaluated, "order_id") == "ORD-000001"


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
            {"order_id": "ORD-DUP", "order_ts": "2025-06-01 10:00:00", "quantity": "1"},
            {"order_id": "ORD-DUP", "order_ts": "2025-07-01 10:00:00", "quantity": "9"},
        )
        evaluated = evaluate(job, orders_spec, frame)
        by_quantity = {
            row["_typed_quantity"]: row["reject_reason"]
            for row in evaluated.select("_typed_quantity", "reject_reason").collect()
        }
        assert by_quantity[9] == ""
        assert "duplicate order_id" in by_quantity[1]

    def test_distinct_keys_are_untouched(self, job, orders_spec, make_raw):
        frame = make_raw({"order_id": "ORD-A"}, {"order_id": "ORD-B"})
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

    def test_every_row_survives_cleaning(self, job, orders_spec, sample_frame):
        evaluated = job.evaluate_rows(sample_frame, orders_spec)
        rejected = evaluated.filter("reject_reason != ''").collect()
        assert evaluated.count() == 19
        assert not rejected, [row["reject_reason"] for row in rejected]

    def test_dimensions_collapse_to_their_canonical_values(self, job, orders_spec, sample_frame):
        clean = job.select_clean(job.evaluate_rows(sample_frame, orders_spec), orders_spec)

        def distinct(column):
            return {row[column] for row in clean.select(column).distinct().collect()}

        assert distinct("region") == {"APAC", "EMEA", "LATAM", "NORTH AMERICA"}
        assert distinct("channel") == {"online", "partner", "retail", "wholesale"}
        assert distinct("category") == {
            "accessories",
            "board games",
            "digital",
            "miniatures",
            "puzzles",
            "trading cards",
        }

    def test_the_dollar_prefixed_price_is_recovered(self, job, orders_spec, sample_frame):
        clean = job.select_clean(job.evaluate_rows(sample_frame, orders_spec), orders_spec)
        row = clean.filter("order_id = 'ORD-004362'").first()
        assert row["unit_price_usd"] == Decimal("159.28")
        assert row["gross_amount_usd"] == Decimal("318.56")

    def test_the_blank_shipping_days_row_is_kept(self, job, orders_spec, sample_frame):
        clean = job.select_clean(job.evaluate_rows(sample_frame, orders_spec), orders_spec)
        assert clean.filter("order_id = 'ORD-004926'").first()["shipping_days"] is None

    def test_the_sku_conflict_is_reported(self, job, orders_spec, sample_frame, capsys):
        # SKU-1067 maps to two products. A row-level transform cannot fix it, so
        # it must at least be visible in the logs.
        clean = job.select_clean(job.evaluate_rows(sample_frame, orders_spec), orders_spec)
        job.log_consistency(clean, orders_spec)
        output = capsys.readouterr().out
        assert "SKU-1067" in output
        assert "WARNING" in output
