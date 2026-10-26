-- Two query-cost fixes, no behaviour change:
--  1. The admin page's "kind = 'adjustment'" listing scanned the whole credits ledger, which
--     grows by a usage row per paid minute. A partial index over the rare adjustments serves it.
--  2. stats.online_per_script ran scripts.can_view once per open session. It now counts per
--     script first and checks visibility once per script.

-- 1. adjustments index ------------------------------------------------------------------

CREATE INDEX "credits_ledger_adjustments_idx" ON "payments"."credits_ledger" USING "btree" ("id" DESC) WHERE ("kind" = 'adjustment'::"payments"."credit_kind");

-- 2. online_per_script ------------------------------------------------------------------

CREATE OR REPLACE FUNCTION "stats"."online_per_script"() RETURNS TABLE ("script_id" "uuid", "users" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  WITH online AS MATERIALIZED (
    SELECT s.script_id, count(DISTINCT s.user_id) AS users
    FROM payments.sessions s
    WHERE s.ended_at IS NULL
      AND s.last_seen > now() - make_interval(mins => (SELECT c.session_timeout_minutes FROM payments.config c))
    GROUP BY s.script_id
  )
  SELECT o.script_id, o.users
  FROM online o
  WHERE scripts.can_view(profiles.uid(), o.script_id);
$$;
