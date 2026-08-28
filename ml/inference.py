"""SageMaker inference handler for the refund-risk model.

The managed scikit-learn container has default handlers, but its default
`predict_fn` calls `model.predict()` and returns a class label. This model
exists to give a *risk score*, so the whole point is `predict_proba`. Hence an
explicit handler.

The feature list is imported from `features.py`, not restated. All three files
ship in the same source archive, so there is exactly one definition of what the
model consumes — restating it here is how inference and training drift apart
(D-27).

Accepts, on `application/json`:

    {"instances": [{"region": "EMEA", ...}, ...]}
    [{"region": "EMEA", ...}]
    {"region": "EMEA", ...}

and CSV with a header row on `text/csv`.
"""

import json
import os

import joblib
import pandas as pd

from features import FEATURES
from train import METADATA_FILENAME, MODEL_FILENAME

JSON_CONTENT_TYPE = "application/json"
CSV_CONTENT_TYPE = "text/csv"


def model_fn(model_dir):
    """Load the pipeline. Preprocessing rides inside it, so nothing else here
    touches the features (D-27)."""
    pipeline = joblib.load(os.path.join(model_dir, MODEL_FILENAME))

    # Provenance in the endpoint's own logs, so a surprising prediction can be
    # traced to the rows the model learned from.
    metadata_path = os.path.join(model_dir, METADATA_FILENAME)
    if os.path.exists(metadata_path):
        with open(metadata_path) as handle:
            metadata = json.load(handle)
        print(
            f"[inference] model trained {metadata.get('trained_at')} "
            f"from {metadata.get('training_data_uri')} "
            f"({metadata.get('training_rows')} rows)"
        )

    return pipeline


def _rows_from_json(payload):
    parsed = json.loads(payload)

    if isinstance(parsed, dict):
        # {"instances": [...]} is the conventional shape; a bare object is one row.
        rows = parsed.get("instances", parsed) if "instances" in parsed else [parsed]
    else:
        rows = parsed

    if not isinstance(rows, list):
        rows = [rows]
    if not rows:
        raise ValueError("no instances in request")
    if not all(isinstance(row, dict) for row in rows):
        raise ValueError("each instance must be a JSON object")

    return rows


def input_fn(request_body, content_type=JSON_CONTENT_TYPE):
    if content_type.startswith(CSV_CONTENT_TYPE):
        from io import StringIO

        frame = pd.DataFrame(pd.read_csv(StringIO(request_body)))
    elif content_type.startswith(JSON_CONTENT_TYPE):
        frame = pd.DataFrame(_rows_from_json(request_body))
    else:
        raise ValueError(f"unsupported content type: {content_type}")

    missing = [column for column in FEATURES if column not in frame.columns]
    if missing:
        raise ValueError(f"missing required fields: {missing}")

    # Column order must match training; the pipeline selects by name, but being
    # explicit keeps a reordered payload from being a surprise.
    return frame[FEATURES]


def predict_fn(input_data, model):
    """Probability of the positive class, which is what a risk score means."""
    return model.predict_proba(input_data)[:, 1]


def output_fn(prediction, accept=JSON_CONTENT_TYPE):
    body = {
        "predictions": [
            {"refund_probability": round(float(value), 6)} for value in prediction
        ]
    }
    return json.dumps(body), JSON_CONTENT_TYPE
