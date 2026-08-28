"""Training script: feature contract, pipeline shape, and honest metrics.

No SageMaker and no AWS — the script is written so the same code runs on a
laptop, which is what makes it testable at all.
"""

import importlib.util
import json
import re
import sys
from pathlib import Path

import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
VIEW_SQL = ROOT / "sql" / "migrations" / "005_ml_training_view.sql"


@pytest.fixture(scope="session")
def train():
    # Registered in sys.modules under its real name, as the SageMaker container
    # does. Without that the fitted pipeline cannot be pickled: it references
    # features.normalise_text by module path.
    sys.path.insert(0, str(ROOT / "ml"))
    import features  # noqa: F401

    spec = importlib.util.spec_from_file_location("train", ROOT / "ml" / "train.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["train"] = module
    spec.loader.exec_module(module)
    return module


def view_select_list():
    """Column names the training view produces, by alias where one is given."""
    sql = VIEW_SQL.read_text()
    body = re.search(r"\bSELECT\b(.*?)\bFROM\s+analytics\.orders", sql, re.S | re.I)
    assert body, "could not locate the SELECT list in the view"

    columns = []
    for item in body.group(1).split(","):
        item = " ".join(item.split())
        if not item:
            continue
        alias = re.search(r"\bAS\s+(\w+)$", item, re.I)
        columns.append(alias.group(1) if alias else item.split(".")[-1])
    return columns


@pytest.fixture
def frame(train):
    """A small but valid training frame: both classes, one null to impute."""
    rows = [
        ("ord-1", "emea", "retail", "puzzles", 1, 10.0, 0.00, 3, 1, 0),
        ("ord-2", "emea", "online", "puzzles", 2, 20.0, 0.10, 9, 2, 1),
        ("ord-3", "apac", "retail", "digital", 1, 15.0, 0.00, 2, 3, 0),
        ("ord-4", "apac", "partner", "digital", 4, 40.0, 0.25, 14, 4, 1),
        ("ord-5", "latam", "retail", "puzzles", 1, 12.0, 0.00, 4, 5, 0),
        ("ord-6", None, "wholesale", "digital", 3, 30.0, 0.05, 11, 6, 1),
    ]
    columns = train.ID_COLUMNS + train.FEATURES + [train.TARGET]
    return pd.DataFrame(rows, columns=columns)


class TestFeatureContract:
    def test_script_and_view_agree_on_columns(self, train):
        """The view is what feeds this script. If they drift, training fails at
        runtime on a real UNLOAD — cheaper to catch here."""
        expected = set(train.ID_COLUMNS) | set(train.FEATURES) | {train.TARGET}
        assert set(view_select_list()) == expected

    def test_lambda_required_fields_match_the_model(self, train):
        """The API proxy validates required fields so a bad request never
        reaches the endpoint. Its list comes from Terraform, so it can drift
        from the model's — this is the guard."""
        terraform = (ROOT / "envs" / "dev" / "variables.tf").read_text()
        block = re.search(
            r'variable "predict_required_fields".*?default\s*=\s*\[(.*?)\]',
            terraform, re.S,
        )
        assert block, "predict_required_fields not found in variables.tf"
        declared = re.findall(r'"([a-z_]+)"', block.group(1))
        assert declared == train.FEATURES

    @pytest.mark.parametrize(
        "path,description",
        [
            ("README.md", "the worked example"),
            ("scripts/smoke_test_endpoint.sh", "the smoke test payloads"),
        ],
    )
    def test_example_payloads_carry_every_required_field(self, train, path, description):
        """The contract appears in five places: the training view, this script,
        the Terraform-declared API contract, the README example, and the smoke
        test. Each one without a drift test has gone stale in turn — the README
        first, then the smoke test, both within a turn of the feature list
        changing. This covers the two that are prose rather than code.

        Payloads that are *meant* to be incomplete are skipped: a request with
        one field is the rejection case, not drift.
        """
        text = (ROOT / path).read_text()

        # Inline `{"instances":[{...}]}` blocks, plus shell payload variables.
        # The smoke test factors its payloads into ORDER= and OTHER=, which the
        # inline pattern alone does not see — the very payloads most likely to
        # go stale.
        payloads = re.findall(r'\{"instances":\s*\[\{(.*?)\}\]', text, re.S)
        payloads += re.findall(r"^(?:ORDER|OTHER)='\{(.*?)\}'", text, re.M)
        assert payloads, f"no example request found in {path}"

        complete = [p for p in payloads if len(re.findall(r'"[a-z_]+":', p)) > 1]
        assert complete, f"no complete example in {path} ({description})"

        for payload in complete:
            fields = set(re.findall(r'"([a-z_]+)":', payload))
            missing = set(train.FEATURES) - fields
            assert not missing, f"{path}: {description} is missing {sorted(missing)}"

    def test_the_smoke_test_shares_one_payload_definition(self):
        """The payloads used to be repeated inline per case, so adding a field
        meant editing each one and missing some. They now come from two
        variables."""
        script = (ROOT / "scripts" / "smoke_test_endpoint.sh").read_text()
        assert re.search(r"^ORDER='", script, re.M)
        assert re.search(r"^OTHER='", script, re.M)

    def test_no_feature_is_listed_twice(self, train):
        assert len(train.FEATURES) == len(set(train.FEATURES))
        assert not set(train.CATEGORICAL_FEATURES) & set(train.NUMERIC_FEATURES)

    @pytest.mark.parametrize(
        "column,reason",
        [
            ("order_status", "the label"),
            ("net_amount_usd", "derived from discount_pct, already a feature"),
            ("etl_job_run_id", "pipeline metadata"),
        ],
    )
    def test_leaking_columns_are_absent(self, train, column, reason):
        assert column not in train.FEATURES, reason
        assert column not in view_select_list(), reason

    def test_shipping_days_is_a_feature_not_leakage(self, train):
        """TR-15. It reads like leakage and is not: the column is populated on
        pending orders, which have not shipped, and cancelled ones, which never
        will — so it is an estimate available when the order is placed."""
        assert "shipping_days" in train.FEATURES
        assert "shipping_days" in view_select_list()

    def test_the_label_is_not_also_a_feature(self, train):
        assert train.TARGET not in train.FEATURES

    def test_view_trains_only_on_resolved_orders(self):
        # A pending order has not resolved, so labelling it 0 would teach the
        # model that unresolved means not-refunded.
        sql = VIEW_SQL.read_text().lower()
        assert "where order_status in" in sql
        assert "'pending'" not in sql.split("where")[1]

    def test_view_reads_the_snapshot_view_not_the_history_table(self):
        # landing.orders holds every snapshot; training on it would see each
        # order once per ETL run.
        sql = VIEW_SQL.read_text().lower()
        assert "from analytics.orders" in sql
        assert "from landing.orders" not in sql


class TestPipeline:
    def test_preprocessing_ships_inside_the_model(self, train):
        # D-27: one object, one code path, so inference cannot preprocess
        # differently from training.
        pipeline = train.build_pipeline(train.parse_args([]))
        assert [name for name, _ in pipeline.steps] == ["normalise", "preprocess", "model"]

    def test_text_normalisation_ships_inside_the_model(self, train, frame):
        """The ETL lowercases every string column, so the model learned from
        lowercase values. Without the same cleaning at inference, "EMEA" would
        be an unseen category encoded as all zeros — a quietly worse prediction
        rather than an error. It lives in the pipeline so both paths share it."""
        pipeline = train.build_pipeline(train.parse_args([]))
        pipeline.fit(frame[train.FEATURES], frame[train.TARGET])

        tidy = pd.DataFrame([{
            "region": "emea", "channel": "retail", "category": "puzzles",
            "quantity": 2, "unit_price_usd": 30.0, "discount_pct": 0.0,
            "shipping_days": 4, "order_dow": 3,
        }])
        shouty = tidy.copy()
        shouty.loc[0, ["region", "channel", "category"]] = ["  EMEA ", "Retail", "PUZZLES"]

        assert pipeline.predict_proba(tidy)[0][1] == pipeline.predict_proba(shouty)[0][1]

    def test_unseen_categories_do_not_raise(self, train, frame):
        pipeline = train.build_pipeline(train.parse_args([]))
        pipeline.fit(frame[train.FEATURES], frame[train.TARGET])

        unseen = pd.DataFrame(
            [{"region": "antarctica", "channel": "carrier-pigeon", "category": "unheard-of",
              "quantity": 1, "unit_price_usd": 9.99, "discount_pct": 0.0,
              "shipping_days": 7, "order_dow": 0}]
        )
        probability = pipeline.predict_proba(unseen)[0][1]
        assert 0.0 <= probability <= 1.0

    def test_nulls_are_imputed_rather_than_dropped(self, train, frame):
        pipeline = train.build_pipeline(train.parse_args([]))
        pipeline.fit(frame[train.FEATURES], frame[train.TARGET])
        assert len(pipeline.predict(frame[train.FEATURES])) == len(frame)


class TestMetrics:
    def test_refuses_to_score_when_a_class_is_too_small(self, train, frame):
        single_positive = frame.copy()
        single_positive[train.TARGET] = [0, 0, 0, 0, 0, 1]
        result = train.evaluate(
            train.build_pipeline(train.parse_args([])),
            single_positive[train.FEATURES], single_positive[train.TARGET], folds=3, seed=1,
        )
        # Reporting a number here would look like evidence and would not be.
        assert result["status"] == "skipped"
        assert "1 row" in result["reason"]

    def test_reports_out_of_fold_metrics_when_it_can(self, train, frame):
        result = train.evaluate(
            train.build_pipeline(train.parse_args([])),
            frame[train.FEATURES], frame[train.TARGET], folds=3, seed=1,
        )
        assert result["status"] == "ok"
        assert 0.0 <= result["roc_auc"] <= 1.0


class TestEndToEnd:
    def test_writes_an_artifact_and_its_provenance(self, train, frame, tmp_path):
        data_dir, model_dir = tmp_path / "train", tmp_path / "model"
        data_dir.mkdir()
        frame.to_csv(data_dir / "training.csv", index=False)

        metadata = train.main(
            ["--train", str(data_dir), "--model-dir", str(model_dir),
             "--training-data-uri", "s3://bucket/training/v1/"]
        )

        assert (model_dir / train.MODEL_FILENAME).exists()
        assert metadata["training_data_uri"] == "s3://bucket/training/v1/"
        assert metadata["training_rows"] == len(frame)
        assert metadata["positive_rows"] == int(frame[train.TARGET].sum())

        written = json.loads((model_dir / train.METADATA_FILENAME).read_text())
        assert written["target"] == train.TARGET
        assert written["features"]["categorical"] == train.CATEGORICAL_FEATURES

    def test_single_class_data_fails_rather_than_training(self, train, frame, tmp_path):
        data_dir, model_dir = tmp_path / "train", tmp_path / "model"
        data_dir.mkdir()
        frame.assign(**{train.TARGET: 0}).to_csv(data_dir / "training.csv", index=False)

        with pytest.raises(SystemExit):
            train.main(["--train", str(data_dir), "--model-dir", str(model_dir)])

    def test_missing_feature_column_fails_loudly(self, train, frame, tmp_path):
        data_dir, model_dir = tmp_path / "train", tmp_path / "model"
        data_dir.mkdir()
        frame.drop(columns=["region"]).to_csv(data_dir / "training.csv", index=False)

        with pytest.raises(SystemExit, match="diverged"):
            train.main(["--train", str(data_dir), "--model-dir", str(model_dir)])

    def test_finds_unloaded_files_without_a_csv_extension(self, train, frame, tmp_path):
        # Redshift UNLOAD only appends .csv when EXTENSION is given.
        data_dir, model_dir = tmp_path / "train", tmp_path / "model"
        data_dir.mkdir()
        frame.to_csv(data_dir / "orders_000", index=False)

        metadata = train.main(["--train", str(data_dir), "--model-dir", str(model_dir)])
        assert metadata["training_rows"] == len(frame)
