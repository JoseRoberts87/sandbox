"""The feature contract, and the cleaning that must match the ETL.

A module of its own for a reason that is not organisational. SageMaker script
mode runs the training entry point as `__main__`, so a function referenced by
the fitted pipeline would be pickled as `__main__.normalise_text` — and the
inference container runs `inference.py` as its entry point, where that name does
not resolve. The model would train successfully and fail to load.

Importing from a named module both entry points share makes the reference
`features.normalise_text` in either direction.
"""

TARGET = "is_refunded"
ID_COLUMNS = ["order_id"]

# Must match the SELECT list in sql/migrations/005_ml_training_view.sql, and the
# `predict_required_fields` the API validates against. Tests assert all three.
CATEGORICAL_FEATURES = ["region", "channel", "category"]

# shipping_days is included deliberately (TR-15). It looks like leakage and is
# not: it is populated on pending orders, which have not shipped, and cancelled
# ones, which never will — so it is an estimate available when the order is
# placed. If the source says otherwise, remove it here and from the training
# view together, or the drift test fails.
NUMERIC_FEATURES = [
    "quantity",
    "unit_price_usd",
    "discount_pct",
    "shipping_days",
    "order_dow",
]

FEATURES = CATEGORICAL_FEATURES + NUMERIC_FEATURES


def normalise_text(frame):
    """Apply the ETL's text cleaning to the categorical features.

    The ETL trims, collapses whitespace and lowercases every string column, so
    the model learned from lowercase values. A caller sending "EMEA" would hit
    `handle_unknown="ignore"` and be encoded as all zeros — a silently degraded
    prediction rather than an error, which is the exact failure D-27 exists to
    prevent.

    This belongs in the pipeline rather than in the inference handler, so it
    ships inside the artifact and both paths share it by construction. On
    training data, where the ETL has already done it, it is a no-op.
    """
    frame = frame.copy()

    for column in CATEGORICAL_FEATURES:
        if column in frame.columns:
            frame[column] = frame[column].map(
                lambda value: None
                if value is None or value != value  # NaN is not equal to itself
                else " ".join(str(value).split()).lower()
            )

    return frame
