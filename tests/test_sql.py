"""Static checks over the SQL.

Migrations are applied by hand against a live warehouse, so a mistake costs a
round trip and possibly a broken environment. These are cheap and encode
failures that have actually happened here.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = sorted((ROOT / "sql" / "migrations").glob("*.sql"))
OPERATIONS = sorted(p for p in (ROOT / "sql").glob("*.sql"))

# Supplied by scripts/redshift_sql.sh from terraform outputs.
FROM_OUTPUTS = {"glue_database", "redshift_role_arn", "aws_region"}
# Supplied per invocation as KEY=VALUE.
FROM_ARGUMENTS = {"ingest_date", "training_prefix"}


def statements(path):
    lines = [ln for ln in path.read_text().splitlines() if not ln.strip().startswith("--")]
    return [s.strip() for s in "\n".join(lines).split(";") if s.strip()]


class TestMigrations:
    def test_there_are_migrations(self):
        assert MIGRATIONS

    @pytest.mark.parametrize("path", MIGRATIONS, ids=lambda p: p.name)
    def test_numbered_so_the_order_is_explicit(self, path):
        assert re.match(r"^\d{3}_[a-z0-9_]+\.sql$", path.name)

    def test_numbers_are_unique_and_contiguous(self):
        numbers = [int(p.name[:3]) for p in MIGRATIONS]
        assert numbers == sorted(numbers)
        assert len(set(numbers)) == len(numbers)

    @pytest.mark.parametrize("path", MIGRATIONS, ids=lambda p: p.name)
    def test_no_migration_drops_anything(self, path):
        """A rebuild does not belong in an ordered, re-runnable sequence.

        Putting one at the end failed: a later migration cannot repair a schema
        that earlier migrations already built views over, and a DROP that runs
        on every `make migrate` would silently empty the warehouse. Destructive
        one-offs live in `sql/`, run deliberately — see
        `sql/rebuild_landing_orders.sql`.
        """
        for statement in statements(path):
            assert not re.match(r"^\s*DROP\s", statement, re.I), statement[:80]

    @pytest.mark.parametrize("path", MIGRATIONS, ids=lambda p: p.name)
    def test_every_statement_is_re_runnable(self, path):
        """`make migrate` is run repeatedly; a plain CREATE would fail the
        second time and take the rest of the file down with it."""
        for statement in statements(path):
            assert re.match(
                r"^\s*CREATE\s+(OR\s+REPLACE\s+)?(EXTERNAL\s+)?(SCHEMA|TABLE|VIEW)\s+"
                r"(IF\s+NOT\s+EXISTS\s+)?",
                statement,
                re.I,
            ), statement[:80]
            if not re.search(r"OR\s+REPLACE", statement, re.I):
                assert re.search(r"IF\s+NOT\s+EXISTS", statement, re.I), statement[:80]


class TestPlaceholders:
    @pytest.mark.parametrize(
        "path", MIGRATIONS + OPERATIONS, ids=lambda p: p.name
    )
    def test_every_placeholder_can_actually_be_supplied(self, path):
        """`redshift_sql.sh` fails loudly on an unknown placeholder rather than
        substituting an empty string, so a typo here is a failed run."""
        used = set(re.findall(r"\$\{(\w+)\}", path.read_text()))
        assert used <= FROM_OUTPUTS | FROM_ARGUMENTS, used - (FROM_OUTPUTS | FROM_ARGUMENTS)


class TestSchemaAgreement:
    """The load names columns explicitly, so its list and the table must match."""

    def test_load_column_list_matches_the_landing_table(self):
        table = (ROOT / "sql" / "migrations" / "003_landing_orders.sql").read_text()
        body = re.search(r"CREATE TABLE IF NOT EXISTS landing\.orders\s*\((.*?)\n\)", table, re.S)
        assert body
        declared = [
            re.match(r"\s*([a-z_]+)\s", line).group(1)
            for line in body.group(1).splitlines()
            if re.match(r"\s*[a-z_]+\s+[A-Z]", line)
        ]

        load = (ROOT / "sql" / "load_orders.sql").read_text()
        insert = re.search(r"INSERT INTO landing\.orders \((.*?)\)", load, re.S)
        assert insert
        inserted = re.findall(r"[a-z_]+", insert.group(1))

        assert inserted == declared, (
            f"only in table: {set(declared) - set(inserted)}; "
            f"only in load: {set(inserted) - set(declared)}"
        )

    def test_training_view_reads_the_snapshot_view(self):
        view = (ROOT / "sql" / "migrations" / "005_ml_training_view.sql").read_text().lower()
        assert "from analytics.orders" in view
        assert "from landing.orders" not in view
