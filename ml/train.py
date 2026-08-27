"""SageMaker script-mode training: refund risk for takehome/orders.

Predicts whether an order will end up refunded, from information available when
the order is placed. Row selection, the label, and leakage exclusions live in
`sql/migrations/005_ml_training_view.sql`; this file consumes what that view
UNLOADs and owns only the row-local transforms.

**The artifact is a single sklearn Pipeline** — imputation, encoding, scaling and
the classifier together. That is the whole point of D-27: inference cannot apply
different preprocessing from training, because there is only one object and one
code path. Anything that splits them reintroduces training/serving skew, which
looks fine offline and is miserable to diagnose in production.

Run under SageMaker:
    the container supplies SM_CHANNEL_TRAIN and SM_MODEL_DIR.

Run locally:
    python ml/train.py --train <dir-of-csv> --model-dir <output-dir>
"""

import argparse
import glob
import json
import os
import sys
from datetime import datetime, timezone

import joblib
import pandas as pd
import sklearn
from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.model_selection import StratifiedKFold, cross_val_predict
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

TARGET = "is_refunded"
ID_COLUMNS = ["order_id"]

# Must match the SELECT list in 005_ml_training_view.sql. A mismatch is caught
# at training time by the column check in load_training_data().
CATEGORICAL_FEATURES = ["region", "channel", "category"]
NUMERIC_FEATURES = ["quantity", "unit_price_usd", "discount_pct", "order_dow"]
FEATURES = CATEGORICAL_FEATURES + NUMERIC_FEATURES

MODEL_FILENAME = "model.joblib"
METADATA_FILENAME = "model_metadata.json"


def log(message):
    print(f"[train] {message}", flush=True)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)

    # SageMaker passes these through the environment; the defaults let the same
    # script run unchanged on a laptop.
    parser.add_argument("--train", default=os.environ.get("SM_CHANNEL_TRAIN", "/opt/ml/input/data/train"))
    parser.add_argument("--model-dir", default=os.environ.get("SM_MODEL_DIR", "/opt/ml/model"))

    parser.add_argument("--training-data-uri", default=os.environ.get("TRAINING_DATA_URI", "unknown"))
    parser.add_argument("--class-weight", default="balanced", choices=["balanced", "none"])
    parser.add_argument("--max-iter", type=int, default=1000)
    parser.add_argument("--c", dest="regularisation_c", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--cv-folds", type=int, default=3)

    return parser.parse_args(argv)


def load_training_data(directory):
    paths = sorted(glob.glob(os.path.join(directory, "**", "*.csv"), recursive=True))
    if not paths:
        # Redshift UNLOAD only appends .csv when EXTENSION is given; fall back to
        # whatever the channel holds rather than failing on a naming detail.
        paths = sorted(
            path
            for path in glob.glob(os.path.join(directory, "**", "*"), recursive=True)
            if os.path.isfile(path) and not os.path.basename(path).startswith(".")
        )
    if not paths:
        sys.exit(f"[train] FAILED: no training files under {directory}")

    frame = pd.concat((pd.read_csv(path) for path in paths), ignore_index=True)

    missing = [column for column in FEATURES + [TARGET] if column not in frame.columns]
    if missing:
        sys.exit(
            f"[train] FAILED: training data is missing {missing}. "
            "The view and this script's feature list have diverged."
        )

    return frame


def build_pipeline(args):
    """Preprocessing and model as one object, so they cannot be applied apart."""
    categorical = Pipeline(
        [
            ("impute", SimpleImputer(strategy="most_frequent")),
            # An unseen region at inference must produce a prediction, not a 500.
            ("encode", OneHotEncoder(handle_unknown="ignore")),
        ]
    )
    numeric = Pipeline(
        [
            ("impute", SimpleImputer(strategy="median")),
            ("scale", StandardScaler()),
        ]
    )
    preprocess = ColumnTransformer(
        [
            ("categorical", categorical, CATEGORICAL_FEATURES),
            ("numeric", numeric, NUMERIC_FEATURES),
        ]
    )
    model = LogisticRegression(
        class_weight=None if args.class_weight == "none" else "balanced",
        max_iter=args.max_iter,
        C=args.regularisation_c,
        random_state=args.seed,
    )
    return Pipeline([("preprocess", preprocess), ("model", model)])


def evaluate(pipeline, features, labels, folds, seed):
    """Out-of-fold metrics, or an honest refusal when the data is too small.

    Reporting in-sample accuracy on a handful of rows would be worse than
    reporting nothing: it looks like evidence and is not.
    """
    minority = int(min(labels.sum(), len(labels) - labels.sum()))
    usable_folds = min(folds, minority)

    if usable_folds < 2:
        return {
            "status": "skipped",
            "reason": f"smallest class has {minority} row(s); cross-validation needs at least 2",
        }

    splitter = StratifiedKFold(n_splits=usable_folds, shuffle=True, random_state=seed)
    probabilities = cross_val_predict(
        pipeline, features, labels, cv=splitter, method="predict_proba"
    )[:, 1]

    return {
        "status": "ok",
        "folds": usable_folds,
        "roc_auc": round(float(roc_auc_score(labels, probabilities)), 4),
        "average_precision": round(float(average_precision_score(labels, probabilities)), 4),
    }


def main(argv=None):
    args = parse_args(argv)

    frame = load_training_data(args.train)
    features, labels = frame[FEATURES], frame[TARGET].astype(int)

    positives = int(labels.sum())
    log(f"{len(frame)} rows, {positives} refunded ({positives / len(frame):.0%})")

    if labels.nunique() < 2:
        sys.exit("[train] FAILED: training data contains only one class; nothing to learn")

    pipeline = build_pipeline(args)
    metrics = evaluate(pipeline, features, labels, args.cv_folds, args.seed)

    if metrics["status"] == "ok":
        log(f"cross-validated ROC AUC {metrics['roc_auc']} over {metrics['folds']} folds")
    else:
        log(f"metrics skipped: {metrics['reason']}")

    if len(frame) < 100:
        log(
            "WARNING: this dataset is far too small for the metrics above to mean "
            "anything. The artifact demonstrates the pipeline, not a model fit for use."
        )

    pipeline.fit(features, labels)

    os.makedirs(args.model_dir, exist_ok=True)
    joblib.dump(pipeline, os.path.join(args.model_dir, MODEL_FILENAME))

    # Shipped with the artifact so a prediction can be traced back to the rows it
    # was trained on (D-24).
    metadata = {
        "target": TARGET,
        "features": {"categorical": CATEGORICAL_FEATURES, "numeric": NUMERIC_FEATURES},
        "training_data_uri": args.training_data_uri,
        "training_rows": int(len(frame)),
        "positive_rows": positives,
        "positive_rate": round(positives / len(frame), 4),
        "metrics": metrics,
        "hyperparameters": {
            "class_weight": args.class_weight,
            "max_iter": args.max_iter,
            "C": args.regularisation_c,
            "seed": args.seed,
        },
        "sklearn_version": sklearn.__version__,
        "trained_at": datetime.now(timezone.utc).isoformat(),
    }
    with open(os.path.join(args.model_dir, METADATA_FILENAME), "w") as handle:
        json.dump(metadata, handle, indent=2)

    log(f"model written to {args.model_dir}")
    return metadata


if __name__ == "__main__":
    main()
