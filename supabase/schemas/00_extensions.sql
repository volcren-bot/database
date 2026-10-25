-- Extensions the schema relies on, and the pg_cron jobs (the jobs only name functions by string,
-- so they can come before the schemas that define them).
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- Ends sessions whose loader stopped sending heartbeats
SELECT cron.schedule('payments-end-stale-sessions', '* * * * *', $$SELECT payments.end_stale_sessions()$$);

-- stats.totals is not refreshed automatically
SELECT cron.schedule('stats-refresh-totals', '*/10 * * * *', $$REFRESH MATERIALIZED VIEW stats.totals$$);
