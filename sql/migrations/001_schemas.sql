-- Schema layout (D-24).
--
--   landing    load target; mirrors the processed Parquet, one row per source row
--   analytics  curated, what people and dashboards read
--   ml         the exact training views SageMaker reads, so "which rows did
--              model v3 train on" stays answerable (empty until Q-02 is settled)

CREATE SCHEMA IF NOT EXISTS landing;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS ml;
