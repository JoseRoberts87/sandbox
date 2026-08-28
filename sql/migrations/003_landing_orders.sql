-- Mirrors the processed Parquet for takehome/orders, plus the partition column.
-- The load names columns explicitly, so a reordering upstream cannot silently
-- misalign values.
--
-- Two types are worth noting:
--
--   order_ts        BIGINT — a Unix epoch in seconds, UTC. The source carries
--                   four different formats; storing the epoch removes the
--                   question of which one a row arrived in. Read it with
--                   TIMESTAMP 'epoch' + order_ts * INTERVAL '1 second', or use
--                   order_date / order_year / order_month / order_dow.
--
--   money columns   DOUBLE PRECISION rather than DECIMAL, because a missing
--                   price must be representable as NaN and DECIMAL cannot hold
--                   one. This trades exactness for that, so monetary sums are
--                   subject to floating-point error.

CREATE TABLE IF NOT EXISTS landing.orders (
    order_id              VARCHAR(32)      NOT NULL,
    order_ts              BIGINT           NOT NULL,
    customer_id           VARCHAR(32),
    region                VARCHAR(64),
    channel               VARCHAR(32),
    product_sku           VARCHAR(32)      NOT NULL,
    product_name          VARCHAR(256),
    category              VARCHAR(64),
    quantity              INTEGER,
    unit_price_usd        DOUBLE PRECISION,
    discount_pct          DOUBLE PRECISION,
    order_status          VARCHAR(32),
    shipping_days         INTEGER,

    -- derived
    order_date            DATE,
    order_year            INTEGER,
    order_month           INTEGER,
    order_dow             INTEGER,
    gross_amount_usd      DOUBLE PRECISION,
    net_amount_usd        DOUBLE PRECISION,
    discount_amount_usd   DOUBLE PRECISION,
    is_discounted         BOOLEAN,
    is_digital            BOOLEAN,
    is_anonymous_customer BOOLEAN,
    customer_order_seq    INTEGER,

    -- lineage
    etl_source_file       VARCHAR(1024),
    etl_processed_at      TIMESTAMP,
    etl_job_run_id        VARCHAR(128),
    ingest_date           DATE             NOT NULL
)
DISTSTYLE AUTO
COMPOUND SORTKEY (ingest_date, order_date);
