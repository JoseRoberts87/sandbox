-- The exact rows and columns the model trains on (D-24, T-4.6).
--
-- Keeping this as a view in the warehouse is the warehouse half of D-27:
-- row selection, label definition and leakage exclusions live here, where they
-- are reviewable in SQL. Encoding and scaling live in the model artifact, so
-- training and inference run one code path and cannot drift apart.
--
-- Label: did the order end up refunded?
--
-- Only terminal orders are included. A `pending` order has not resolved yet, so
-- labelling it 0 would teach the model that "unresolved" means "not refunded" —
-- and at scoring time every new order is pending, which is precisely the
-- population we care about.
--
-- shipping_days IS included (TR-15). It was previously excluded as leakage, on
-- the reasoning that it is known only after shipping. That reasoning was wrong:
-- the column is populated on `pending` orders, which have not shipped, and on
-- `cancelled` orders, which never will. It is an estimate made at order time,
-- so it is available at scoring time and is a legitimate feature. Worth
-- confirming with the source (T-2.16); if it turns out to be an actual
-- duration, remove it here and from FEATURES in ml/train.py together.
--
-- Excluded as leakage or artefact:
--   order_status         the label
--   net_amount_usd       derived from discount_pct, already a feature
--   gross_amount_usd     quantity * unit_price_usd, both already features
--   discount_amount_usd  likewise
--   product_sku          identifies nothing — one SKU maps to many products
--   hour of order_ts     many source rows carry a date with no time, so hour
--                        would encode which timestamp format the row arrived
--                        in — a property of our ETL, not of the order
--   etl_*                pipeline metadata
--
-- order_dow comes from the processed table rather than being derived here, so
-- analytics and the model share one definition (TR-13).
--
-- Reads analytics.orders, not landing.orders: the view pins the newest
-- snapshot, so training cannot silently see each order once per ETL run.

CREATE OR REPLACE VIEW ml.orders_training AS
SELECT
    order_id,
    region,
    channel,
    category,
    quantity,
    unit_price_usd,
    discount_pct,
    shipping_days,
    order_dow,
    CASE WHEN order_status = 'refunded' THEN 1 ELSE 0 END AS is_refunded
FROM analytics.orders
WHERE order_status IN ('completed', 'cancelled', 'refunded');
