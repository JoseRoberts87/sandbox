-- Load one snapshot from the processed zone into landing (T-3.5).
--
-- Idempotent by delete-then-insert on the partition, matching how the ETL
-- rewrites a partition in S3 (D-19). Re-running a date replaces it.
--
-- Both statements run in a single transaction: the Data API's
-- batch-execute-statement wraps a batch in one, which is why there is no
-- explicit BEGIN/COMMIT here — adding one would conflict with it.
--
-- Requires: ingest_date

DELETE FROM landing.orders
WHERE ingest_date = DATE '${ingest_date}';

INSERT INTO landing.orders (
    order_id, order_ts, customer_id, region, channel,
    product_sku, product_name, category, quantity, unit_price_usd,
    discount_pct, order_status, shipping_days,
    order_date, order_year, order_month, order_dow,
    gross_amount_usd, net_amount_usd, discount_amount_usd,
    is_discounted, is_digital, is_anonymous_customer, customer_order_seq,
    etl_source_file, etl_processed_at, etl_job_run_id, ingest_date
)
SELECT
    order_id, order_ts, customer_id, region, channel,
    product_sku, product_name, category, quantity, unit_price_usd,
    discount_pct, order_status, shipping_days,
    order_date, order_year, order_month, order_dow,
    gross_amount_usd, net_amount_usd, discount_amount_usd,
    is_discounted, is_digital, is_anonymous_customer, customer_order_seq,
    etl_source_file, etl_processed_at, etl_job_run_id,
    CAST(ingest_date AS DATE)
FROM processed_ext.takehome_orders
WHERE ingest_date = '${ingest_date}';
