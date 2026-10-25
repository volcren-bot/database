SET local check_function_bodies = off;

DROP POLICY "scripts SELECT for allowed" ON "storage"."objects";

ALTER TABLE "stats"."online"
  DROP CONSTRAINT "online_script_id_fkey";

ALTER TABLE "stats"."online"
  DROP CONSTRAINT "online_user_id_fkey";

DROP FUNCTION "payments"."charge_usage"(uuid, uuid, integer);

DROP FUNCTION "payments"."post_credits"(uuid, payments.credit_kind, bigint, uuid, uuid, integer, text);

DROP FUNCTION "payments"."post_earnings"(uuid, payments.earning_kind, bigint, uuid, integer, text);

DROP TABLE "stats"."online";

CREATE TABLE "payments"."sessions" (
  "id"            uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"       uuid                     NOT NULL,
  "script_id"     uuid                     NOT NULL,
  "author_id"     uuid                     NOT NULL,
  "revision"      integer                  NOT NULL,
  "price"         bigint                   NOT NULL,
  "started_at"    timestamp with time zone NOT NULL DEFAULT now(),
  "last_seen"     timestamp with time zone NOT NULL DEFAULT now(),
  "charged_until" timestamp with time zone NOT NULL DEFAULT now(),
  "ended_at"      timestamp with time zone,
  "unpaid"        bigint                   NOT NULL DEFAULT 0,
  CONSTRAINT "sessions_pkey" PRIMARY KEY (id),
  CONSTRAINT "sessions_price_check" CHECK ((price >= 0)),
  CONSTRAINT "sessions_unpaid_check" CHECK ((unpaid >= 0))
);

ALTER TABLE "payments"."sessions"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "payments"."config"
  ADD COLUMN "batch_minutes" integer NOT NULL DEFAULT 5;

ALTER TABLE "payments"."config"
  ADD COLUMN "session_timeout_minutes" integer NOT NULL DEFAULT 5;

ALTER TABLE "payments"."config"
  ADD COLUMN "min_balance_batches" integer NOT NULL DEFAULT 1;

ALTER TABLE "payments"."credits_ledger"
  ADD COLUMN "session_id" uuid;

ALTER TABLE "payments"."earnings_ledger"
  ADD COLUMN "session_id" uuid;

CREATE TYPE "payments"."session_end" AS ENUM (
  'stopped',
  'timeout',
  'insufficient_credits'
);

ALTER TABLE "payments"."sessions"
  ADD COLUMN "end_reason" payments.session_end;

CREATE OR REPLACE FUNCTION payments.charge_session (
  p_session uuid,
  p_minutes integer
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_session payments.sessions;
  v_cost bigint;
  v_available bigint;
  v_charged bigint;
  v_share bigint;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session % not found', p_session;
  END IF;

  IF v_session.price = 0 OR p_minutes <= 0 THEN
    RETURN 0;
  END IF;

  v_cost := v_session.price * p_minutes;

  -- lock the account so concurrent sessions can't both spend the same credits
  SELECT credits INTO v_available FROM payments.accounts WHERE user_id = v_session.user_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no payment account for user %', v_session.user_id;
  END IF;

  v_charged := LEAST(v_cost, v_available);

  IF v_charged < v_cost THEN
    UPDATE payments.sessions SET unpaid = unpaid + (v_cost - v_charged) WHERE id = p_session;
  END IF;

  IF v_charged > 0 THEN
    PERFORM payments.post_credits(v_session.user_id, 'usage', -v_charged, NULL, v_session.script_id, p_minutes, NULL, p_session);

    v_share := v_charged * (10000 - (SELECT platform_fee_bps FROM payments.config)) / 10000;

    IF v_share > 0 THEN
      PERFORM payments.post_earnings(v_session.author_id, 'sale', v_share, v_session.script_id, p_minutes, NULL, p_session);
    END IF;
  END IF;

  RETURN v_charged;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.end_session (
  p_session uuid,
  p_reason  payments.session_end
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_session payments.sessions;
  v_minutes integer;
  v_charged bigint;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session % not found', p_session;
  END IF;

  IF v_session.ended_at IS NOT NULL THEN
    RETURN 0;
  END IF;

  v_minutes := GREATEST(ceil(extract(epoch FROM (v_session.last_seen - v_session.charged_until)) / 60)::integer, 0);

  IF v_minutes = 0 AND v_session.charged_until = v_session.started_at THEN
    v_minutes := 1;
  END IF;

  v_charged := payments.charge_session(p_session, v_minutes);

  UPDATE payments.sessions
  SET ended_at = now(), end_reason = p_reason, charged_until = charged_until + make_interval(mins => v_minutes)
  WHERE id = p_session;

  RETURN v_charged;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.end_stale_sessions()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_id uuid;
  v_count integer := 0;
BEGIN
  FOR v_id IN
    SELECT id FROM payments.sessions
    WHERE ended_at IS NULL
      AND last_seen < now() - make_interval(mins => (SELECT session_timeout_minutes FROM payments.config))
  LOOP
    PERFORM payments.end_session(v_id, 'timeout');
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.heartbeat_session (
  p_session uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_session payments.sessions;
  v_config payments.config;
  v_minutes integer;
  v_balance bigint;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session FOR UPDATE;

  IF NOT FOUND OR v_session.ended_at IS NOT NULL THEN
    RETURN false;
  END IF;

  SELECT * INTO v_config FROM payments.config;

  UPDATE payments.sessions SET last_seen = now() WHERE id = p_session;

  v_minutes := floor(extract(epoch FROM (now() - v_session.charged_until)) / 60)::integer;

  IF v_minutes >= v_config.batch_minutes THEN
    PERFORM payments.charge_session(p_session, v_minutes);

    UPDATE payments.sessions SET charged_until = charged_until + make_interval(mins => v_minutes) WHERE id = p_session;
  END IF;

  IF v_session.price > 0 THEN
    SELECT credits INTO v_balance FROM payments.accounts WHERE user_id = v_session.user_id;

    IF COALESCE(v_balance, 0) < v_session.price * v_config.batch_minutes * v_config.min_balance_batches THEN
      PERFORM payments.end_session(p_session, 'insufficient_credits');
      RETURN false;
    END IF;
  END IF;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.post_credits (
  p_user    uuid,
  p_kind    payments.credit_kind,
  p_amount  bigint,
  p_payment uuid                 DEFAULT NULL::uuid,
  p_script  uuid                 DEFAULT NULL::uuid,
  p_minutes integer              DEFAULT NULL::integer,
  p_note    text                 DEFAULT NULL::text,
  p_session uuid                 DEFAULT NULL::uuid
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_balance bigint;
BEGIN
  UPDATE payments.accounts
  SET credits = credits + p_amount, updated_at = now()
  WHERE user_id = p_user
  RETURNING credits INTO v_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no payment account for user %', p_user;
  END IF;

  INSERT INTO payments.credits_ledger (user_id, kind, amount, balance_after, payment_id, script_id, session_id, minutes, note)
  VALUES (p_user, p_kind, p_amount, v_balance, p_payment, p_script, p_session, p_minutes, p_note);

  RETURN v_balance;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.post_earnings (
  p_user    uuid,
  p_kind    payments.earning_kind,
  p_amount  bigint,
  p_script  uuid                  DEFAULT NULL::uuid,
  p_minutes integer               DEFAULT NULL::integer,
  p_note    text                  DEFAULT NULL::text,
  p_session uuid                  DEFAULT NULL::uuid
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_balance bigint;
BEGIN
  UPDATE payments.accounts
  SET earnings = earnings + p_amount, updated_at = now()
  WHERE user_id = p_user
  RETURNING earnings INTO v_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no payment account for user %', p_user;
  END IF;

  INSERT INTO payments.earnings_ledger (user_id, kind, amount, balance_after, script_id, session_id, minutes, note)
  VALUES (p_user, p_kind, p_amount, v_balance, p_script, p_session, p_minutes, p_note);

  RETURN v_balance;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.start_session (
  p_user   uuid,
  p_script uuid
)
  RETURNS TABLE (
    session_id uuid,
    revision   integer,
    files      text[]
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_author uuid;
  v_revision integer;
  v_listed_price bigint;
  v_price bigint;
  v_files text[];
  v_config payments.config;
  v_id uuid;
BEGIN
  IF NOT scripts.can_access(p_user, p_script) THEN
    RAISE EXCEPTION 'script not accessible' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT p.author, p.revision, m.price INTO v_author, v_revision, v_listed_price
  FROM scripts.protected p
  JOIN scripts.metadata m ON m.id = p.id
  WHERE p.id = p_script;

  SELECT v.files INTO v_files FROM scripts.versions v
  WHERE v.id = p_script AND v.revision = v_revision AND v.status = 'live'::scripts.version_status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'script % has no live revision', p_script;
  END IF;

  v_price := CASE
    WHEN v_author = p_user OR profiles.min_role(p_user, 'tester'::profiles.roles) THEN 0
    ELSE v_listed_price
  END;

  SELECT * INTO v_config FROM payments.config;

  IF v_price > 0 AND COALESCE((SELECT a.credits FROM payments.accounts a WHERE a.user_id = p_user), 0)
                     < v_price * v_config.batch_minutes * v_config.min_balance_batches THEN
    RAISE EXCEPTION 'insufficient credits' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO payments.sessions AS s (user_id, script_id, author_id, revision, price)
  VALUES (p_user, p_script, v_author, v_revision, v_price)
  RETURNING s.id INTO v_id;

  RETURN QUERY SELECT v_id, v_revision, v_files;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.is_object_author (
  user_id     uuid,
  object_name text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT CASE
    WHEN split_part(object_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN scripts.is_author(user_id, split_part(object_name, '/', 1)::uuid)
    ELSE false
  END;
$function$;

CREATE OR REPLACE FUNCTION stats.online_count()
  RETURNS bigint
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT count(DISTINCT s.user_id)
  FROM payments.sessions s
  WHERE s.ended_at IS NULL
    AND s.last_seen > now() - make_interval(mins => (SELECT c.session_timeout_minutes FROM payments.config c));
$function$;

CREATE OR REPLACE FUNCTION stats.online_per_script()
  RETURNS TABLE (
    script_id uuid,
    users     bigint
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT s.script_id, count(DISTINCT s.user_id)
  FROM payments.sessions s
  WHERE s.ended_at IS NULL
    AND s.last_seen > now() - make_interval(mins => (SELECT c.session_timeout_minutes FROM payments.config c))
    AND scripts.can_view(profiles.uid(), s.script_id)
  GROUP BY s.script_id;
$function$;

ALTER TABLE "payments"."config"
  ADD CONSTRAINT "config_batch_check" CHECK (((batch_minutes > 0) AND (session_timeout_minutes > 0) AND (min_balance_batches > 0)));

ALTER TABLE "payments"."sessions"
  ADD CONSTRAINT "sessions_end_check" CHECK (((ended_at IS NULL) = (end_reason IS NULL)));

CREATE INDEX sessions_open_last_seen_idx ON payments.sessions USING btree (last_seen)
  WHERE (ended_at IS NULL);

CREATE INDEX sessions_user_id_idx ON payments.sessions USING btree (user_id, started_at DESC);

CREATE POLICY "SELECT for OWNER" ON "payments"."sessions"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = profiles.uid()));

CREATE POLICY "scripts SELECT for author" ON "storage"."objects"
  FOR SELECT
  TO "authenticated"
  USING (((bucket_id = 'scripts'::text) AND (scripts.is_object_author(profiles.uid(), name) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles))));

COMMENT ON COLUMN "payments"."config"."batch_minutes" IS 'A running session is charged once this many minutes have passed since the last charge.';

COMMENT ON COLUMN "payments"."config"."min_balance_batches" IS 'A session needs a balance of at least price * batch_minutes * this to start and to keep running.';

COMMENT ON COLUMN "payments"."config"."session_timeout_minutes" IS 'A session without a heartbeat for this long is ended with reason timeout.';

COMMENT ON TABLE "payments"."sessions" IS 'Usage sessions. price is fixed when the session starts (0 for free scripts and for the author and tester+). unpaid is the part of a charge the balance could not cover.';

REVOKE ALL ON FUNCTION "payments"."charge_session"(uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."charge_session"(uuid, integer) TO "postgres";

REVOKE ALL ON FUNCTION "payments"."end_session"(uuid, payments.session_end) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."end_session"(uuid, payments.session_end) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."end_stale_sessions"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."end_stale_sessions"() TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."heartbeat_session"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."heartbeat_session"(uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."post_credits"(uuid, payments.credit_kind, bigint, uuid, uuid, integer, text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."post_credits"(uuid, payments.credit_kind, bigint, uuid, uuid, integer, text, uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."post_earnings"(uuid, payments.earning_kind, bigint, uuid, integer, text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."post_earnings"(uuid, payments.earning_kind, bigint, uuid, integer, text, uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."start_session"(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."start_session"(uuid, uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."is_object_author"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."is_object_author"(uuid, text) TO "authenticated", "postgres", "service_role";

GRANT SELECT ON TABLE "payments"."sessions" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "payments"."sessions" TO "postgres";

GRANT SELECT ON TABLE "payments"."sessions" TO "service_role";

GRANT USAGE ON TYPE "payments"."session_end" TO "postgres";

-- ==== Hand-written (no schema diff captures these) ====

-- Cron jobs. cron.schedule with a name replaces an existing job of that name.
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

SELECT cron.schedule('payments-end-stale-sessions', '* * * * *', $$SELECT payments.end_stale_sessions()$$);

-- stats.totals was never refreshed before
SELECT cron.schedule('stats-refresh-totals', '*/10 * * * *', $$REFRESH MATERIALIZED VIEW stats.totals$$);
