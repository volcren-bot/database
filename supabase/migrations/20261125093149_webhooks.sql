SET local check_function_bodies = off;

CREATE SCHEMA "webhooks";

CREATE TABLE "webhooks"."deliveries" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "endpoint_id"     uuid                     NOT NULL,
  "payload"         jsonb                    NOT NULL,
  "attempts"        smallint                 NOT NULL DEFAULT 0,
  "next_attempt_at" timestamp with time zone NOT NULL DEFAULT now(),
  "response_status" smallint,
  "error"           text,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "finished_at"     timestamp with time zone,
  CONSTRAINT "deliveries_error_check" CHECK (((error IS NULL) OR (char_length(error) <= 500))),
  CONSTRAINT "deliveries_pkey" PRIMARY KEY (id)
);

ALTER TABLE "webhooks"."deliveries"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "webhooks"."endpoints" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"         uuid                     NOT NULL,
  "name"            text                     NOT NULL,
  "url"             text                     NOT NULL,
  "bearer_token"    text,
  "header_names"    text[]                   NOT NULL DEFAULT '{}'::text[],
  "header_values"   text[]                   NOT NULL DEFAULT '{}'::text[],
  "signing_secret"  text                     NOT NULL DEFAULT encode(extensions.gen_random_bytes(32), 'hex'::text),
  "enabled"         boolean                  NOT NULL DEFAULT true,
  "failures"        integer                  NOT NULL DEFAULT 0,
  "disabled_reason" text,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "endpoints_bearer_check" CHECK (((bearer_token IS NULL) OR (char_length(bearer_token) <= 4096) AND (bearer_token ~ '^[!-~]+$'::text))),
  CONSTRAINT "endpoints_failures_check" CHECK ((failures >= 0)),
  CONSTRAINT "endpoints_name_check" CHECK (((name = btrim(name)) AND (char_length(name) >= 1) AND (char_length(name) <= 64))),
  CONSTRAINT "endpoints_pkey" PRIMARY KEY (id)
);

ALTER TABLE "webhooks"."endpoints"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "webhooks"."endpoints"
  ADD COLUMN "has_bearer" boolean GENERATED ALWAYS AS ((bearer_token IS NOT NULL)) STORED;

CREATE TYPE "webhooks"."delivery_status" AS ENUM (
  'pending',
  'delivered',
  'failed'
);

ALTER TABLE "webhooks"."deliveries"
  ADD COLUMN "status" webhooks.delivery_status NOT NULL DEFAULT 'pending'::webhooks.delivery_status;

CREATE TYPE "webhooks"."event" AS ENUM (
  'client_release',
  'script_check',
  'ping'
);

ALTER TABLE "webhooks"."deliveries"
  ADD COLUMN "event" webhooks.event NOT NULL;

ALTER TABLE "webhooks"."endpoints"
  ADD COLUMN "events" webhooks.event[] NOT NULL;

CREATE TYPE "webhooks"."format" AS ENUM (
  'volcren',
  'github_dispatch',
  'text',
  'discord'
);

ALTER TABLE "webhooks"."endpoints"
  ADD COLUMN "format" webhooks.format NOT NULL DEFAULT 'volcren'::webhooks.format;

CREATE OR REPLACE FUNCTION scripts.record_check (
  p_script   uuid,
  p_revision integer,
  p_injector text,
  p_problems jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_problems jsonb := NULLIF(p_problems, '[]'::jsonb);
  v_checked scripts.injectors;
  v_version scripts.versions;
BEGIN
  SELECT * INTO v_checked FROM scripts.injectors i WHERE i.version = p_injector;

  IF NOT FOUND OR v_checked.retired_at IS NOT NULL THEN
    RAISE EXCEPTION 'a check names a registered injector that isn''t retired' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE scripts.versions v
  SET checked_injector = p_injector, checked_at = now(), problems = v_problems
  WHERE v.id = p_script AND v.revision = p_revision
    AND v.status IN ('pending'::scripts.version_status, 'live'::scripts.version_status)
  RETURNING * INTO v_version;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no pending or live revision % of script %', p_revision, p_script USING ERRCODE = 'no_data_found';
  END IF;

  IF v_version.status = 'live'::scripts.version_status
     AND v_problems IS NULL
     AND COALESCE((v_version.manifest ->> 'auto_forward')::boolean, true)
     AND NOT EXISTS (
       SELECT 1 FROM scripts.injectors pinned
       WHERE pinned.version = v_version.injector AND pinned.retired_at IS NULL AND pinned.build >= v_checked.build
     ) THEN
    UPDATE scripts.versions v SET injector = p_injector
    WHERE v.id = p_script AND v.revision = p_revision;

    UPDATE scripts.protected p SET broken = false
    WHERE p.id = p_script AND p.revision = p_revision;

    v_version.injector := p_injector;
  END IF;

  IF v_version.status = 'live'::scripts.version_status THEN
    PERFORM webhooks.enqueue('script_check'::webhooks.event, jsonb_build_object(
        'script_id', p_script,
        'title', s.title,
        'url', s.url,
        'revision', p_revision,
        'checked_injector', p_injector,
        'injector', v_version.injector,
        'passed', v_problems IS NULL,
        'problem_count', COALESCE(jsonb_array_length(v_problems), 0),
        'problems', COALESCE((SELECT jsonb_agg(pr.value ORDER BY pr.ordinality) FROM jsonb_array_elements(v_problems) WITH ORDINALITY pr WHERE pr.ordinality <= 10), '[]'::jsonb)),
      pt.author)
    FROM scripts.scripts s JOIN scripts.protected pt ON pt.id = s.id
    WHERE s.id = p_script;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION webhooks.can_use (
  p_user uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT EXISTS (
    SELECT 1 FROM profiles.profiles p
    WHERE p.id = p_user AND p.role >= 'contributor'::profiles.roles AND p.banned_at IS NULL
  );
$function$;

CREATE OR REPLACE FUNCTION webhooks.claim_deliveries (
  p_limit integer
)
  RETURNS TABLE (
    id             uuid,
    event          webhooks.event,
    payload        jsonb,
    attempts       smallint,
    created_at     timestamp with time zone,
    url            text,
    format         webhooks.format,
    bearer_token   text,
    header_names   text[],
    header_values  text[],
    signing_secret text
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  UPDATE webhooks.deliveries d
  SET status = 'failed'::webhooks.delivery_status, finished_at = now(),
    error = 'The webhook was turned off, or its owner can no longer use webhooks, before this was delivered.'
  FROM webhooks.endpoints e
  WHERE e.id = d.endpoint_id AND d.status = 'pending'::webhooks.delivery_status
    AND ((NOT e.enabled AND d.event <> 'ping'::webhooks.event) OR NOT webhooks.can_use(e.user_id));

  RETURN QUERY
  WITH due AS (
    SELECT d.id FROM webhooks.deliveries d
    WHERE d.status = 'pending'::webhooks.delivery_status AND d.next_attempt_at <= now()
    ORDER BY d.next_attempt_at
    LIMIT LEAST(GREATEST(p_limit, 1), 100)
    FOR UPDATE SKIP LOCKED
  ), claimed AS (
    UPDATE webhooks.deliveries d
    SET attempts = d.attempts + 1, next_attempt_at = now() + interval '2 minutes'
    FROM due WHERE d.id = due.id
    RETURNING d.id, d.endpoint_id, d.event, d.payload, d.attempts, d.created_at
  )
  SELECT c.id, c.event, c.payload, c.attempts, c.created_at, e.url, e.format, e.bearer_token,
    e.header_names, e.header_values, e.signing_secret
  FROM claimed c JOIN webhooks.endpoints e ON e.id = c.endpoint_id;
END;
$function$;

CREATE OR REPLACE FUNCTION webhooks.delete_old_deliveries()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_count integer;
BEGIN
  DELETE FROM webhooks.deliveries d WHERE d.finished_at < now() - interval '30 days';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION webhooks.enqueue (
  p_event   webhooks.event,
  p_payload jsonb,
  p_user    uuid           DEFAULT NULL::uuid
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_count integer;
BEGIN
  INSERT INTO webhooks.deliveries (endpoint_id, event, payload)
  SELECT e.id, p_event, p_payload
  FROM webhooks.endpoints e
  WHERE e.enabled AND p_event = ANY (e.events)
    AND (p_user IS NULL OR e.user_id = p_user)
    AND webhooks.can_use(e.user_id);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION webhooks.finish_delivery (
  p_id     uuid,
  p_status integer,
  p_error  text,
  p_retry  boolean
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_delivery webhooks.deliveries;
  v_final boolean;
BEGIN
  SELECT * INTO v_delivery FROM webhooks.deliveries d
  WHERE d.id = p_id AND d.status = 'pending'::webhooks.delivery_status
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF p_status BETWEEN 200 AND 299 THEN
    UPDATE webhooks.deliveries d
    SET status = 'delivered'::webhooks.delivery_status, response_status = p_status, error = NULL, finished_at = now()
    WHERE d.id = p_id;

    UPDATE webhooks.endpoints e SET failures = 0 WHERE e.id = v_delivery.endpoint_id AND e.failures > 0;
    RETURN;
  END IF;

  v_final := NOT COALESCE(p_retry, false) OR v_delivery.event = 'ping'::webhooks.event OR v_delivery.attempts >= 6;

  UPDATE webhooks.deliveries d
  SET response_status = CASE WHEN p_status BETWEEN 100 AND 599 THEN p_status END,
    error = left(COALESCE(p_error, 'The endpoint answered ' || p_status), 500),
    status = CASE WHEN v_final THEN 'failed'::webhooks.delivery_status ELSE 'pending'::webhooks.delivery_status END,
    finished_at = CASE WHEN v_final THEN now() END,
    next_attempt_at = CASE WHEN v_final THEN d.next_attempt_at
      ELSE now() + make_interval(secs => (ARRAY[60, 300, 1800, 7200, 21600])[LEAST(v_delivery.attempts, 5)]) END
  WHERE d.id = p_id;

  IF v_delivery.event <> 'ping'::webhooks.event THEN
    UPDATE webhooks.endpoints e
    SET failures = e.failures + 1,
      enabled = e.enabled AND e.failures + 1 < 15,
      disabled_reason = CASE WHEN e.enabled AND e.failures + 1 >= 15
        THEN 'Turned off after 15 failed attempts in a row.' ELSE e.disabled_reason END
    WHERE e.id = v_delivery.endpoint_id;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION webhooks.rotate_signing_secret (
  p_id uuid
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_secret text := encode(extensions.gen_random_bytes(32), 'hex');
BEGIN
  IF auth.uid() IS NULL OR NOT webhooks.can_use(auth.uid()) THEN
    RAISE EXCEPTION 'webhooks need the contributor role' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE webhooks.endpoints e SET signing_secret = v_secret, updated_at = now()
  WHERE e.id = p_id AND e.user_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'webhook not found' USING ERRCODE = 'no_data_found';
  END IF;
  RETURN v_secret;
END;
$function$;

CREATE OR REPLACE FUNCTION webhooks.save_endpoint (
  p_id           uuid,
  p_name         text,
  p_url          text,
  p_format       webhooks.format,
  p_events       webhooks.event[],
  p_enabled      boolean,
  p_bearer_token text,
  p_headers      jsonb
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_old webhooks.endpoints;
  v_names text[] := '{}';
  v_values text[] := '{}';
  v_header jsonb;
  v_name text;
  v_value text;
  v_index integer;
  v_events webhooks.event[];
  v_bearer text;
  v_id uuid;
BEGIN
  IF v_user IS NULL OR NOT webhooks.can_use(v_user) THEN
    RAISE EXCEPTION 'webhooks need the contributor role' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT * INTO v_old FROM webhooks.endpoints e WHERE e.id = p_id AND e.user_id = v_user FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'webhook not found' USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  IF p_headers IS NULL OR jsonb_typeof(p_headers) <> 'array' THEN
    RAISE EXCEPTION 'headers must be an array' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR v_header IN SELECT h FROM jsonb_array_elements(p_headers) h LOOP
    IF jsonb_typeof(v_header) <> 'object' OR jsonb_typeof(v_header -> 'name') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_header -> 'value') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'each header needs a name and a value' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    v_name := v_header ->> 'name';
    v_value := v_header ->> 'value';
    IF v_value IS NULL THEN
      v_index := (SELECT o.i FROM unnest(COALESCE(v_old.header_names, '{}')) WITH ORDINALITY AS o(n, i) WHERE lower(o.n) = lower(v_name));
      IF v_index IS NULL THEN
        RAISE EXCEPTION 'header % has no value to keep', v_name USING ERRCODE = 'invalid_parameter_value';
      END IF;
      v_value := v_old.header_values[v_index];
    END IF;
    v_names := v_names || v_name;
    v_values := v_values || v_value;
  END LOOP;

  IF NOT webhooks.valid_headers(v_names, v_values) THEN
    RAISE EXCEPTION 'invalid headers' USING ERRCODE = 'check_violation';
  END IF;

  v_events := ARRAY(SELECT DISTINCT e FROM unnest(p_events) e ORDER BY e);
  v_bearer := CASE WHEN p_bearer_token IS NULL THEN v_old.bearer_token ELSE NULLIF(p_bearer_token, '') END;

  IF p_id IS NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext('webhooks.endpoints.' || v_user::text));
    IF (SELECT count(*) FROM webhooks.endpoints e WHERE e.user_id = v_user) >= 5 THEN
      RAISE EXCEPTION 'at most 5 webhooks per account' USING ERRCODE = 'program_limit_exceeded';
    END IF;

    INSERT INTO webhooks.endpoints (user_id, name, url, format, events, bearer_token, header_names, header_values, enabled)
    VALUES (v_user, btrim(p_name), btrim(p_url), p_format, v_events, v_bearer, v_names, v_values, COALESCE(p_enabled, true))
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;

  UPDATE webhooks.endpoints e
  SET name = btrim(p_name), url = btrim(p_url), format = p_format, events = v_events, bearer_token = v_bearer,
    header_names = v_names, header_values = v_values, enabled = COALESCE(p_enabled, e.enabled),
    failures = CASE WHEN COALESCE(p_enabled, e.enabled) AND NOT e.enabled THEN 0 ELSE e.failures END,
    disabled_reason = CASE WHEN COALESCE(p_enabled, e.enabled) THEN NULL ELSE e.disabled_reason END,
    updated_at = now()
  WHERE e.id = p_id;
  RETURN p_id;
END;
$function$;

CREATE OR REPLACE FUNCTION webhooks.send_test (
  p_id uuid
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_id uuid;
BEGIN
  IF v_user IS NULL OR NOT webhooks.can_use(v_user) THEN
    RAISE EXCEPTION 'webhooks need the contributor role' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM webhooks.endpoints e WHERE e.id = p_id AND e.user_id = v_user) THEN
    RAISE EXCEPTION 'webhook not found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('webhooks.endpoints.' || v_user::text));
  IF EXISTS (SELECT 1 FROM webhooks.deliveries d WHERE d.endpoint_id = p_id AND d.event = 'ping'::webhooks.event AND d.status = 'pending'::webhooks.delivery_status)
     OR (SELECT count(*) FROM webhooks.deliveries d JOIN webhooks.endpoints e ON e.id = d.endpoint_id
         WHERE e.user_id = v_user AND d.event = 'ping'::webhooks.event AND d.created_at > now() - interval '1 hour') >= 10 THEN
    RAISE EXCEPTION 'too many tests' USING ERRCODE = 'program_limit_exceeded';
  END IF;

  INSERT INTO webhooks.deliveries (endpoint_id, event, payload)
  VALUES (p_id, 'ping'::webhooks.event, '{}'::jsonb)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION webhooks.tr_injectors_released()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  PERFORM webhooks.enqueue('client_release'::webhooks.event,
    jsonb_build_object('version', NEW.version, 'build', NEW.build, 'released_at', NEW.created_at));
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION webhooks.valid_header (
  name  text,
  value text
)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT name IS NOT NULL AND value IS NOT NULL
    AND name ~ '^[A-Za-z0-9][A-Za-z0-9-]{0,63}$'
    AND lower(name) NOT IN ('host', 'content-length', 'content-type', 'content-encoding', 'transfer-encoding',
      'connection', 'keep-alive', 'upgrade', 'te', 'trailer', 'expect', 'cookie', 'authorization', 'user-agent',
      'forwarded', 'via', 'origin', 'referer', 'accept-encoding', 'date', 'x-real-ip')
    AND lower(name) !~ '^(proxy-|sec-|x-forwarded-|x-volcren-)'
    AND char_length(value) BETWEEN 1 AND 1024 AND value ~ '^[ -~]+$';
$function$;

CREATE OR REPLACE FUNCTION webhooks.valid_headers (
  names text[],
  vals  text[]
)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT names IS NOT NULL AND vals IS NOT NULL
    AND cardinality(names) = cardinality(vals)
    AND cardinality(names) <= 8
    AND (SELECT count(DISTINCT lower(n)) FROM unnest(names) n) = cardinality(names)
    AND COALESCE((SELECT bool_and(webhooks.valid_header(h.n, h.v)) FROM unnest(names, vals) AS h(n, v)), true);
$function$;

CREATE OR REPLACE FUNCTION webhooks.valid_url (
  url text
)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT url IS NOT NULL
    AND char_length(url) <= 2048
    AND url ~ '^https://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]{1,5})?([/?#][!-~]*)?$'
    AND substring(url FROM '^https://([^/:?#]+)') !~ '^[0-9.]+$';
$function$;

ALTER TABLE "webhooks"."endpoints"
  ADD CONSTRAINT "endpoints_events_check" CHECK (((cardinality(events) >= 1) AND (NOT ('ping'::webhooks.event = ANY (events)))));

ALTER TABLE "webhooks"."deliveries"
  ADD CONSTRAINT "deliveries_endpoint_id_fkey" FOREIGN KEY (endpoint_id) REFERENCES webhooks.endpoints(id) ON DELETE CASCADE;

ALTER TABLE "webhooks"."endpoints"
  ADD CONSTRAINT "endpoints_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles.profiles(id) ON DELETE CASCADE;

CREATE INDEX deliveries_due_idx ON webhooks.deliveries USING btree (next_attempt_at)
  WHERE (status = 'pending'::webhooks.delivery_status);

CREATE INDEX deliveries_endpoint_id_idx ON webhooks.deliveries USING btree (endpoint_id, created_at DESC);

CREATE INDEX deliveries_finished_at_idx ON webhooks.deliveries USING btree (finished_at)
  WHERE (finished_at IS NOT NULL);

CREATE INDEX endpoints_user_id_idx ON webhooks.endpoints USING btree (user_id);

CREATE TRIGGER tr_injectors_released
  AFTER INSERT ON scripts.injectors
  FOR EACH ROW
  EXECUTE FUNCTION webhooks.tr_injectors_released();

CREATE POLICY "SELECT for OWNER" ON "webhooks"."deliveries"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM webhooks.endpoints e
  WHERE ((e.id = deliveries.endpoint_id) AND (e.user_id = profiles.uid())))));

CREATE POLICY "DELETE for OWNER" ON "webhooks"."endpoints"
  FOR DELETE
  TO "authenticated"
  USING ((user_id = profiles.uid()));

CREATE POLICY "SELECT for OWNER" ON "webhooks"."endpoints"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = profiles.uid()));

REVOKE ALL ON FUNCTION "webhooks"."can_use"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."can_use"(uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "webhooks"."claim_deliveries"(integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."claim_deliveries"(integer) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "webhooks"."delete_old_deliveries"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."delete_old_deliveries"() TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "webhooks"."enqueue"(webhooks.event, jsonb, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."enqueue"(webhooks.event, jsonb, uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "webhooks"."finish_delivery"(uuid, integer, text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."finish_delivery"(uuid, integer, text, boolean) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "webhooks"."rotate_signing_secret"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."rotate_signing_secret"(uuid) TO "authenticated", "postgres";

REVOKE ALL ON FUNCTION "webhooks"."save_endpoint"(uuid, text, text, webhooks.format, webhooks.event[], boolean, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."save_endpoint"(uuid, text, text, webhooks.format, webhooks.event[], boolean, text, jsonb) TO "authenticated", "postgres";

REVOKE ALL ON FUNCTION "webhooks"."send_test"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."send_test"(uuid) TO "authenticated", "postgres";

REVOKE ALL ON FUNCTION "webhooks"."tr_injectors_released"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."tr_injectors_released"() TO "postgres";

REVOKE ALL ON FUNCTION "webhooks"."valid_header"(text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."valid_header"(text, text) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "webhooks"."valid_headers"(text[], text[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."valid_headers"(text[], text[]) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "webhooks"."valid_url"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "webhooks"."valid_url"(text) TO "authenticated", "postgres", "service_role";

GRANT USAGE ON SCHEMA "webhooks" TO "authenticated";

GRANT CREATE, USAGE ON SCHEMA "webhooks" TO "postgres";

GRANT USAGE ON SCHEMA "webhooks" TO "service_role";

GRANT SELECT ON TABLE "webhooks"."deliveries" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "webhooks"."deliveries" TO "postgres", "service_role";

GRANT SELECT ("created_at") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("disabled_reason") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("enabled") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("events") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("failures") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("format") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("has_bearer") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("header_names") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("id") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("name") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("signing_secret") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("updated_at") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("url") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT SELECT ("user_id") ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT DELETE ON TABLE "webhooks"."endpoints" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "webhooks"."endpoints" TO "postgres", "service_role";

GRANT USAGE ON TYPE "webhooks"."delivery_status" TO "postgres";

GRANT USAGE ON TYPE "webhooks"."event" TO "postgres";

GRANT USAGE ON TYPE "webhooks"."format" TO "postgres";

SELECT cron.schedule_in_database('webhooks-delete-old-deliveries', '41 4 * * *', 'SELECT webhooks.delete_old_deliveries()', 'postgres', NULL, true);

ALTER TABLE "webhooks"."endpoints"
  ADD CONSTRAINT "endpoints_headers_check" CHECK (webhooks.valid_headers(header_names, header_values));

ALTER TABLE "webhooks"."endpoints"
  ADD CONSTRAINT "endpoints_url_check" CHECK (webhooks.valid_url(url));
