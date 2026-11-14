SET local check_function_bodies = off;

CREATE TABLE "payments"."agent_sessions" (
  "id"             uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"        uuid                     NOT NULL,
  "started_at"     timestamp with time zone NOT NULL DEFAULT now(),
  "last_seen"      timestamp with time zone NOT NULL DEFAULT now(),
  "ended_at"       timestamp with time zone,
  "end_reason"     payments.session_end,
  "active_seconds" integer                  NOT NULL DEFAULT 0,
  CONSTRAINT "agent_sessions_active_seconds_check" CHECK ((active_seconds >= 0)),
  CONSTRAINT "agent_sessions_end_check" CHECK (((ended_at IS NULL) = (end_reason IS NULL))),
  CONSTRAINT "agent_sessions_pkey" PRIMARY KEY (id)
);

ALTER TABLE "payments"."agent_sessions"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "payments"."config"
  ADD COLUMN "max_agent_sessions" integer NOT NULL DEFAULT 8;

CREATE OR REPLACE FUNCTION payments.end_agent_session (
  p_user    uuid,
  p_session uuid,
  p_max_gap integer
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_session payments.agent_sessions;
BEGIN
  SELECT * INTO v_session FROM payments.agent_sessions a WHERE a.id = p_session AND a.user_id = p_user FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent session not found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_session.ended_at IS NOT NULL THEN
    RETURN false;
  END IF;

  UPDATE payments.agent_sessions
  SET active_seconds = active_seconds + LEAST(GREATEST(round(extract(epoch FROM now() - last_seen)), 0), GREATEST(p_max_gap, 0))::integer,
      last_seen = now(), ended_at = now(), end_reason = 'stopped'
  WHERE id = p_session;

  RETURN true;
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
  v_timeout interval := make_interval(mins => (SELECT session_timeout_minutes FROM payments.config));
  v_count integer := 0;
  v_agents integer;
BEGIN
  FOR v_id IN
    SELECT id FROM payments.sessions
    WHERE ended_at IS NULL AND last_seen < now() - v_timeout
  LOOP
    BEGIN
      -- lock first and re-check: a heartbeat may have landed since the scan
      PERFORM 1 FROM payments.sessions
      WHERE id = v_id AND ended_at IS NULL AND last_seen < now() - v_timeout
      FOR UPDATE SKIP LOCKED;

      IF FOUND THEN
        PERFORM payments.end_session(v_id, 'timeout');
        v_count := v_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- one broken session must not block the others
      RAISE WARNING 'end_stale_sessions: session % failed: %', v_id, SQLERRM;
    END;
  END LOOP;

  UPDATE payments.agent_sessions
  SET ended_at = now(), end_reason = 'timeout'
  WHERE ended_at IS NULL AND last_seen < now() - v_timeout;
  GET DIAGNOSTICS v_agents = ROW_COUNT;

  RETURN v_count + v_agents;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.heartbeat_agent_session (
  p_user    uuid,
  p_session uuid,
  p_max_gap integer
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_session payments.agent_sessions;
BEGIN
  SELECT * INTO v_session FROM payments.agent_sessions a WHERE a.id = p_session AND a.user_id = p_user FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent session not found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_session.ended_at IS NOT NULL THEN
    RETURN false;
  END IF;

  UPDATE payments.agent_sessions
  SET active_seconds = active_seconds + LEAST(GREATEST(round(extract(epoch FROM now() - last_seen)), 0), GREATEST(p_max_gap, 0))::integer,
      last_seen = now()
  WHERE id = p_session;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.start_agent_session (
  p_user uuid
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF profiles.is_banned(p_user) THEN
    RAISE EXCEPTION 'account banned' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('payments.agent_sessions.' || p_user::text));
  IF (SELECT count(*) FROM payments.agent_sessions a WHERE a.user_id = p_user AND a.ended_at IS NULL)
     >= (SELECT c.max_agent_sessions FROM payments.config c) THEN
    RAISE EXCEPTION 'too many agent sessions' USING ERRCODE = 'program_limit_exceeded';
  END IF;

  INSERT INTO payments.agent_sessions AS a (user_id) VALUES (p_user) RETURNING a.id INTO v_id;
  RETURN v_id;
END;
$function$;

ALTER TABLE "payments"."config"
  ADD CONSTRAINT "config_max_agent_sessions_check" CHECK ((max_agent_sessions > 0));

CREATE INDEX agent_sessions_open_last_seen_idx ON payments.agent_sessions USING btree (last_seen)
  WHERE (ended_at IS NULL);

CREATE INDEX agent_sessions_user_id_idx ON payments.agent_sessions USING btree (user_id, started_at DESC);

COMMENT ON COLUMN "payments"."config"."max_agent_sessions" IS 'Open agent sessions an account may have at once.';

COMMENT ON TABLE "payments"."agent_sessions" IS 'Free agent runs from the loader''s MCP server, metered but never billed. active_seconds adds the time between heartbeats, each gap capped by the API (2 x its heartbeat interval), so a loader that stalls or crashes is not counted past it. No FKs, like sessions.';

REVOKE ALL ON FUNCTION "payments"."end_agent_session"(uuid, uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."end_agent_session"(uuid, uuid, integer) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."heartbeat_agent_session"(uuid, uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."heartbeat_agent_session"(uuid, uuid, integer) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."start_agent_session"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."start_agent_session"(uuid) TO "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "payments"."agent_sessions" TO "postgres";

GRANT SELECT ON TABLE "payments"."agent_sessions" TO "service_role";
