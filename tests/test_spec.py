"""Invariants every dataset spec must hold.

These are cheap and they catch mistakes that would otherwise surface as a
production run quarantining 100% of its rows for no obvious reason. They run
against every entry in DATASET_SPECS, so a dataset added later inherits them.
"""

import re

import pytest

NUMERIC_PREFIXES = ("int", "long", "double", "float", "decimal")


def spec_ids(job):
    return sorted(job.DATASET_SPECS)


@pytest.fixture
def specs(job):
    return job.DATASET_SPECS


def _columns(spec):
    return {column["name"]: column for column in spec["columns"]}


def _all_specs(job):
    return [(name, spec) for name, spec in sorted(job.DATASET_SPECS.items())]


class TestStructure:
    def test_at_least_one_dataset_is_declared(self, job):
        assert job.DATASET_SPECS

    def test_keys_are_source_slash_dataset(self, job):
        for name in job.DATASET_SPECS:
            assert re.fullmatch(r"[a-z0-9_]+/[a-z0-9_]+", name), name

    def test_every_column_is_fully_declared(self, job):
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                assert column.get("name"), f"{name}: column without a name"
                assert column.get("type"), f"{name}:{column['name']} has no type"
                assert column.get("clean"), f"{name}:{column['name']} has no cleaning rule"

    def test_column_names_are_unique(self, job):
        for name, spec in _all_specs(job):
            names = [column["name"] for column in spec["columns"]]
            assert len(names) == len(set(names)), f"{name}: duplicate column names"

    def test_column_names_are_already_normalized(self, job):
        # The job normalizes incoming headers; a spec name that does not survive
        # normalization would never match the frame.
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                assert job.normalize(column["name"]) == column["name"], f"{name}:{column['name']}"


class TestCleaningRules:
    def test_rules_are_ones_the_job_implements(self, job):
        implemented = {"code", "enum", "text", "money", "trim"}
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                assert column["clean"] in implemented, f"{name}:{column['name']}"

    def test_allowed_values_match_the_cleaning_rule_casing(self, job):
        """The killer bug this prevents: `enum` lowercases the value before
        comparing, so an allowed list containing "Retail" rejects every row."""
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                allowed = column.get("allowed")
                if not allowed:
                    continue
                if column["clean"] == "enum":
                    assert all(v == v.lower() for v in allowed), f"{name}:{column['name']}"
                elif column["clean"] == "code":
                    assert all(v == v.upper() for v in allowed), f"{name}:{column['name']}"

    def test_allowed_values_are_unique(self, job):
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                allowed = column.get("allowed", [])
                assert len(allowed) == len(set(allowed)), f"{name}:{column['name']}"

    def test_money_cleaning_only_on_numeric_columns(self, job):
        # money strips every non-numeric character; on a string column that
        # would silently destroy the value.
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                if column["clean"] == "money":
                    assert column["type"].startswith(NUMERIC_PREFIXES), f"{name}:{column['name']}"

    def test_allowed_values_only_on_string_columns(self, job):
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                if "allowed" in column:
                    assert column["type"] == "string", f"{name}:{column['name']}"

    def test_bounds_only_on_numeric_columns(self, job):
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                if "min" in column or "max" in column:
                    assert column["type"].startswith(NUMERIC_PREFIXES), f"{name}:{column['name']}"

    def test_bounds_are_ordered(self, job):
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                if "min" in column and "max" in column:
                    assert column["min"] <= column["max"], f"{name}:{column['name']}"


class TestReferences:
    def test_primary_key_is_a_declared_column(self, job):
        for name, spec in _all_specs(job):
            key = spec.get("primary_key")
            if key:
                assert key in _columns(spec), f"{name}: primary_key {key} is not declared"

    def test_dedup_column_is_declared(self, job):
        for name, spec in _all_specs(job):
            column = spec.get("dedup_order_by")
            if column:
                assert column in _columns(spec), f"{name}: dedup_order_by {column} is not declared"

    def test_dedup_requires_a_primary_key(self, job):
        # Ordering without partitioning would silently do nothing.
        for name, spec in _all_specs(job):
            if spec.get("dedup_order_by"):
                assert spec.get("primary_key"), f"{name}: dedup_order_by without primary_key"

    def test_timestamp_columns_have_formats_declared(self, job):
        for name, spec in _all_specs(job):
            has_timestamp = any(c["type"] == "timestamp" for c in spec["columns"])
            if has_timestamp:
                assert spec.get("timestamp_formats"), f"{name}: timestamp column but no formats"

    def test_timestamp_formats_are_distinct(self, job):
        for name, spec in _all_specs(job):
            formats = spec.get("timestamp_formats", [])
            assert len(formats) == len(set(formats)), f"{name}: duplicate timestamp formats"

    def test_derived_names_do_not_shadow_source_columns(self, job):
        for name, spec in _all_specs(job):
            for derived in spec.get("derived", {}):
                assert derived not in _columns(spec), f"{name}: derived {derived} shadows a column"

    def test_derived_names_do_not_collide_with_lineage_columns(self, job):
        reserved = {"ingest_date", "etl_source_file", "etl_processed_at", "etl_job_run_id"}
        for name, spec in _all_specs(job):
            assert not reserved & set(spec.get("derived", {})), f"{name}: derived shadows lineage"
            assert not reserved & set(_columns(spec)), f"{name}: column shadows lineage"

    def test_consistency_checks_reference_declared_columns(self, job):
        for name, spec in _all_specs(job):
            for check in spec.get("consistency", []):
                assert check["key"] in _columns(spec), f"{name}: {check['key']} is not declared"
                for column in check["expect_single"]:
                    assert column in _columns(spec), f"{name}: {column} is not declared"


class TestOrdersSpec:
    """A few assertions specific to takehome/orders, from the source profile."""

    def test_declares_every_observed_timestamp_format(self, orders_spec):
        assert set(orders_spec["timestamp_formats"]) == {
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "MM/dd/yyyy",
            "dd-MMM-yyyy",
        }

    def test_price_is_double_so_a_missing_value_can_be_nan(self, orders_spec):
        """Deliberate trade. decimal is the right type for money, but it cannot
        represent NaN, and an absent price is required to be NaN. Exactness on
        monetary sums is given up for that."""
        price = _columns(orders_spec)["unit_price_usd"]
        assert price["type"] == "double"
        assert price["missing"] == "nan"

    def test_nan_defaults_only_on_types_that_can_hold_one(self, job):
        for name, spec in _all_specs(job):
            for column in spec["columns"]:
                if column.get("missing") == "nan":
                    assert column["type"] in ("double", "float"), f"{name}:{column['name']}"

    def test_shipping_days_is_optional(self, orders_spec):
        # One row in the source file has no value; it must not be a reject.
        assert not _columns(orders_spec)["shipping_days"].get("required")

    def test_discount_is_a_fraction_not_a_percentage(self, orders_spec):
        discount = _columns(orders_spec)["discount_pct"]
        assert (discount["min"], discount["max"]) == (0, 1)
