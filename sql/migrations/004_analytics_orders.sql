-- The safe entry point for anyone querying orders.
--
-- Every ingest_date partition is a complete snapshot of raw, not an increment
-- (D-12), so SELECT * FROM landing.orders counts each order once per run. This
-- view pins the newest snapshot, which is what "the orders table" should mean.

CREATE OR REPLACE VIEW analytics.orders AS
SELECT *
FROM landing.orders
WHERE ingest_date = (SELECT MAX(ingest_date) FROM landing.orders);
