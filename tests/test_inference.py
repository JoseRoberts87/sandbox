"""SageMaker inference handler.

Runs against a real fitted pipeline — no AWS, no container. The handler is
plain Python precisely so this is possible.
"""

import importlib.util
import json
import sys
from pathlib import Path

import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="session")
def inference():
    # inference.py imports train.py as a sibling, exactly as it does in the
    # container, where both live in the extracted source directory.
    sys.path.insert(0, str(ROOT / "ml"))
    import features  # noqa: F401

    spec = importlib.util.spec_from_file_location("inference", ROOT / "ml" / "inference.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def train():
    sys.path.insert(0, str(ROOT / "ml"))
    spec = importlib.util.spec_from_file_location("train", ROOT / "ml" / "train.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["train"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def model_dir(tmp_path_factory, train):
    """A genuinely fitted artifact, written the way training writes it."""
    directory = tmp_path_factory.mktemp("model")
    data = tmp_path_factory.mktemp("data")

    rows = [
        ("ord-1", "emea", "retail", "puzzles", 1, 10.0, 0.00, 3, 1, 0),
        ("ord-2", "emea", "online", "puzzles", 2, 20.0, 0.10, 9, 2, 1),
        ("ord-3", "apac", "retail", "digital", 1, 15.0, 0.00, 2, 3, 0),
        ("ord-4", "apac", "partner", "digital", 4, 40.0, 0.25, 14, 4, 1),
        ("ord-5", "latam", "retail", "puzzles", 1, 12.0, 0.00, 4, 5, 0),
        ("ord-6", "emea", "wholesale", "digital", 3, 30.0, 0.05, 11, 6, 1),
    ]
    columns = train.ID_COLUMNS + train.FEATURES + [train.TARGET]
    pd.DataFrame(rows, columns=columns).to_csv(data / "training.csv", index=False)

    train.main(["--train", str(data), "--model-dir", str(directory)])
    return directory


@pytest.fixture(scope="session")
def model(inference, model_dir):
    return inference.model_fn(str(model_dir))


ORDER = {
    "region": "emea", "channel": "retail", "category": "puzzles",
    "quantity": 2, "unit_price_usd": 30.0, "discount_pct": 0.0,
    "shipping_days": 4, "order_dow": 3,
}


def predict(inference, model, payload, content_type="application/json"):
    body, _ = inference.output_fn(
        inference.predict_fn(inference.input_fn(payload, content_type), model)
    )
    return json.loads(body)


class TestFeatureContract:
    def test_features_come_from_train_not_a_copy(self, inference, train):
        # One definition. Restating the list here is how inference and training
        # drift apart (D-27).
        assert inference.FEATURES is train.FEATURES or inference.FEATURES == train.FEATURES

    def test_columns_are_ordered_as_trained(self, inference, model):
        scrambled = {k: ORDER[k] for k in reversed(list(ORDER))}
        frame = inference.input_fn(json.dumps({"instances": [scrambled]}))
        assert list(frame.columns) == inference.FEATURES


class TestPayloadShapes:
    def test_instances_wrapper(self, inference, model):
        result = predict(inference, model, json.dumps({"instances": [ORDER]}))
        assert len(result["predictions"]) == 1

    def test_bare_list(self, inference, model):
        assert len(predict(inference, model, json.dumps([ORDER, ORDER]))["predictions"]) == 2

    def test_single_object(self, inference, model):
        assert len(predict(inference, model, json.dumps(ORDER))["predictions"]) == 1

    def test_csv_with_header(self, inference, model):
        csv = ",".join(inference.FEATURES) + "\n" + ",".join(str(ORDER[f]) for f in inference.FEATURES) + "\n"
        assert len(predict(inference, model, csv, "text/csv")["predictions"]) == 1

    def test_content_type_with_charset_suffix(self, inference, model):
        # API Gateway and clients routinely append "; charset=utf-8".
        result = predict(inference, model, json.dumps(ORDER), "application/json; charset=utf-8")
        assert len(result["predictions"]) == 1


class TestOutput:
    def test_returns_a_probability_not_a_class_label(self, inference, model):
        # The container's default predict_fn returns 0/1. A risk score needs the
        # probability, which is the whole reason this handler exists.
        value = predict(inference, model, json.dumps({"instances": [ORDER]}))["predictions"][0]
        assert isinstance(value["refund_probability"], float)
        assert 0.0 <= value["refund_probability"] <= 1.0

    def test_one_prediction_per_instance_in_order(self, inference, model):
        cheap = {**ORDER, "unit_price_usd": 5.0, "discount_pct": 0.0}
        expensive = {**ORDER, "unit_price_usd": 500.0, "discount_pct": 0.9}
        result = predict(inference, model, json.dumps({"instances": [cheap, expensive]}))
        assert len(result["predictions"]) == 2
        assert result["predictions"][0] != result["predictions"][1]

    def test_declares_json_content_type(self, inference, model):
        _, content_type = inference.output_fn([0.5])
        assert content_type == "application/json"


class TestRejections:
    @pytest.mark.parametrize(
        "payload,fragment",
        [
            ('{"instances": []}', "no instances"),
            ("[]", "no instances"),
            ('{"instances": [1, 2]}', "must be a JSON object"),
            ('{"region": "EMEA"}', "missing required fields"),
        ],
    )
    def test_bad_payloads_raise_value_error(self, inference, payload, fragment):
        with pytest.raises(ValueError, match=fragment):
            inference.input_fn(payload)

    def test_unsupported_content_type_is_rejected(self, inference):
        with pytest.raises(ValueError, match="unsupported content type"):
            inference.input_fn("<xml/>", "application/xml")

    def test_missing_field_names_what_is_missing(self, inference):
        partial = {k: v for k, v in ORDER.items() if k != "discount_pct"}
        with pytest.raises(ValueError, match="discount_pct"):
            inference.input_fn(json.dumps(partial))


class TestRobustness:
    def test_unseen_categorical_values_still_score(self, inference, model):
        # An unseen region must produce a prediction, not a 500. This is the
        # first way an endpoint like this fails in production.
        unseen = {**ORDER, "region": "ANTARCTICA", "channel": "carrier-pigeon", "category": "unheard-of"}
        result = predict(inference, model, json.dumps({"instances": [unseen]}))
        assert 0.0 <= result["predictions"][0]["refund_probability"] <= 1.0

    def test_null_feature_is_imputed_not_fatal(self, inference, model):
        result = predict(inference, model, json.dumps({"instances": [{**ORDER, "region": None}]}))
        assert len(result["predictions"]) == 1
