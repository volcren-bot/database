CREATE SCHEMA IF NOT EXISTS "webhooks";

ALTER SCHEMA "webhooks" OWNER TO "postgres";

CREATE TYPE "webhooks"."event" AS ENUM (
    'client_release',
    'script_check',
    'ping'
);

CREATE TYPE "webhooks"."format" AS ENUM (
    'volcren',
    'github_dispatch',
    'text',
    'discord'
);

CREATE TYPE "webhooks"."delivery_status" AS ENUM (
    'pending',
    'delivered',
    'failed'
);


CREATE OR REPLACE FUNCTION "webhooks"."valid_url"("url" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT url IS NOT NULL
    AND char_length(url) <= 2048
    AND url ~ '^https://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]{1,5})?([/?#][!-~]*)?$'
    AND substring(url FROM '^https://([^/:?#]+)') !~ '^[0-9.]+$';
$$;

CREATE OR REPLACE FUNCTION "webhooks"."valid_header"("name" "text", "value" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT name IS NOT NULL AND value IS NOT NULL
    AND name ~ '^[A-Za-z0-9][A-Za-z0-9-]{0,63}$'
    AND lower(name) NOT IN ('host', 'content-length', 'content-type', 'content-encoding', 'transfer-encoding',
      'connection', 'keep-alive', 'upgrade', 'te', 'trailer', 'expect', 'cookie', 'authorization', 'user-agent',
      'forwarded', 'via', 'origin', 'referer', 'accept-encoding', 'date', 'x-real-ip')
    AND lower(name) !~ '^(proxy-|sec-|x-forwarded-|x-volcren-)'
    AND char_length(value) BETWEEN 1 AND 1024 AND value ~ '^[ -~]+$';
$$;

CREATE OR REPLACE FUNCTION "webhooks"."valid_headers"("names" "text"[], "vals" "text"[]) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT names IS NOT NULL AND vals IS NOT NULL
    AND cardinality(names) = cardinality(vals)
    AND cardinality(names) <= 8
    AND (SELECT count(DISTINCT lower(n)) FROM unnest(names) n) = cardinality(names)
    AND COALESCE((SELECT bool_and(webhooks.valid_header(h.n, h.v)) FROM unnest(names, vals) AS h(n, v)), true);
$$;


CREATE TABLE IF NOT EXISTS "webhooks"."endpoints" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "url" "text" NOT NULL,
    "format" "webhooks"."format" DEFAULT 'volcren'::"webhooks"."format" NOT NULL,
    "events" "webhooks"."event"[] NOT NULL,
    "bearer_token" "text",
    "has_bearer" boolean GENERATED ALWAYS AS (("bearer_token" IS NOT NULL)) STORED,
    "header_names" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "header_values" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "signing_secret" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(32), 'hex'::"text") NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "failures" integer DEFAULT 0 NOT NULL,
    "disabled_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "endpoints_name_check" CHECK ((("name" = "btrim"("name")) AND ("char_length"("name") >= 1) AND ("char_length"("name") <= 64))),
    CONSTRAINT "endpoints_url_check" CHECK ("webhooks"."valid_url"("url")),
    CONSTRAINT "endpoints_events_check" CHECK ((("cardinality"("events") >= 1) AND (NOT ('ping'::"webhooks"."event" = ANY ("events"))))),
    CONSTRAINT "endpoints_bearer_check" CHECK ((("bearer_token" IS NULL) OR ("char_length"("bearer_token") <= 4096) AND ("bearer_token" ~ '^[!-~]+$'::"text"))),
    CONSTRAINT "endpoints_headers_check" CHECK ("webhooks"."valid_headers"("header_names", "header_values")),
    CONSTRAINT "endpoints_failures_check" CHECK (("failures" >= 0))
);

CREATE TABLE IF NOT EXISTS "webhooks"."deliveries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "endpoint_id" "uuid" NOT NULL,
    "event" "webhooks"."event" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "webhooks"."delivery_status" DEFAULT 'pending'::"webhooks"."delivery_status" NOT NULL,
    "attempts" smallint DEFAULT 0 NOT NULL,
    "next_attempt_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "response_status" smallint,
    "error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    CONSTRAINT "deliveries_error_check" CHECK ((("error" IS NULL) OR ("char_length"("error") <= 500)))
);


ALTER TABLE ONLY "webhooks"."endpoints"
    ADD CONSTRAINT "endpoints_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "webhooks"."endpoints"
    ADD CONSTRAINT "endpoints_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "webhooks"."deliveries"
    ADD CONSTRAINT "deliveries_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "webhooks"."deliveries"
    ADD CONSTRAINT "deliveries_endpoint_id_fkey" FOREIGN KEY ("endpoint_id") REFERENCES "webhooks"."endpoints"("id") ON DELETE CASCADE;

CREATE INDEX "endpoints_user_id_idx" ON "webhooks"."endpoints" USING "btree" ("user_id");

CREATE INDEX "deliveries_due_idx" ON "webhooks"."deliveries" USING "btree" ("next_attempt_at") WHERE ("status" = 'pending'::"webhooks"."delivery_status");

CREATE INDEX "deliveries_endpoint_id_idx" ON "webhooks"."deliveries" USING "btree" ("endpoint_id", "created_at" DESC);

CREATE INDEX "deliveries_finished_at_idx" ON "webhooks"."deliveries" USING "btree" ("finished_at") WHERE ("finished_at" IS NOT NULL);


CREATE OR REPLACE FUNCTION "webhooks"."can_use"("p_user" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles.profiles p
    WHERE p.id = p_user AND p.role >= 'contributor'::profiles.roles AND p.banned_at IS NULL
  );
$$;

CREATE OR REPLACE FUNCTION "webhooks"."enqueue"("p_event" "webhooks"."event", "p_payload" "jsonb", "p_user" "uuid" DEFAULT NULL::"uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

CREATE OR REPLACE FUNCTION "webhooks"."tr_injectors_released"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  PERFORM webhooks.enqueue('client_release'::webhooks.event,
    jsonb_build_object('version', NEW.version, 'build', NEW.build, 'released_at', NEW.created_at));
  RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER "tr_injectors_released" AFTER INSERT ON "scripts"."injectors" FOR EACH ROW EXECUTE FUNCTION "webhooks"."tr_injectors_released"();


CREATE OR REPLACE FUNCTION "webhooks"."claim_deliveries"("p_limit" integer) RETURNS TABLE ("id" "uuid", "event" "webhooks"."event", "payload" "jsonb", "attempts" smallint, "created_at" timestamp with time zone, "url" "text", "format" "webhooks"."format", "bearer_token" "text", "header_names" "text"[], "header_values" "text"[], "signing_secret" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

CREATE OR REPLACE FUNCTION "webhooks"."finish_delivery"("p_id" "uuid", "p_status" integer, "p_error" "text", "p_retry" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

CREATE OR REPLACE FUNCTION "webhooks"."delete_old_deliveries"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_count integer;
BEGIN
  DELETE FROM webhooks.deliveries d WHERE d.finished_at < now() - interval '30 days';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


CREATE OR REPLACE FUNCTION "webhooks"."save_endpoint"("p_id" "uuid", "p_name" "text", "p_url" "text", "p_format" "webhooks"."format", "p_events" "webhooks"."event"[], "p_enabled" boolean, "p_bearer_token" "text", "p_headers" "jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

CREATE OR REPLACE FUNCTION "webhooks"."rotate_signing_secret"("p_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

CREATE OR REPLACE FUNCTION "webhooks"."send_test"("p_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;


ALTER TABLE "webhooks"."endpoints" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "webhooks"."deliveries" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for OWNER" ON "webhooks"."endpoints" FOR SELECT TO "authenticated"
    USING (("user_id" = "profiles"."uid"()));

CREATE POLICY "DELETE for OWNER" ON "webhooks"."endpoints" FOR DELETE TO "authenticated"
    USING (("user_id" = "profiles"."uid"()));

CREATE POLICY "SELECT for OWNER" ON "webhooks"."deliveries" FOR SELECT TO "authenticated"
    USING ((EXISTS (SELECT 1 FROM "webhooks"."endpoints" "e" WHERE (("e"."id" = "deliveries"."endpoint_id") AND ("e"."user_id" = "profiles"."uid"())))));


GRANT USAGE ON SCHEMA "webhooks" TO "authenticated", "service_role";

REVOKE ALL ON TABLE "webhooks"."endpoints" FROM "anon", "authenticated";
GRANT SELECT ("id", "user_id", "name", "url", "format", "events", "has_bearer", "header_names", "signing_secret", "enabled", "failures", "disabled_reason", "created_at", "updated_at") ON TABLE "webhooks"."endpoints" TO "authenticated";
GRANT DELETE ON TABLE "webhooks"."endpoints" TO "authenticated";
GRANT ALL ON TABLE "webhooks"."endpoints" TO "service_role";

REVOKE ALL ON TABLE "webhooks"."deliveries" FROM "anon", "authenticated";
GRANT SELECT ON TABLE "webhooks"."deliveries" TO "authenticated";
GRANT ALL ON TABLE "webhooks"."deliveries" TO "service_role";

REVOKE ALL ON FUNCTION "webhooks"."valid_url"("url" "text") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "webhooks"."valid_header"("name" "text", "value" "text") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "webhooks"."valid_headers"("names" "text"[], "vals" "text"[]) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "webhooks"."can_use"("p_user" "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "webhooks"."enqueue"("p_event" "webhooks"."event", "p_payload" "jsonb", "p_user" "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "webhooks"."tr_injectors_released"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "webhooks"."claim_deliveries"("p_limit" integer) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "webhooks"."finish_delivery"("p_id" "uuid", "p_status" integer, "p_error" "text", "p_retry" boolean) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "webhooks"."delete_old_deliveries"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "webhooks"."save_endpoint"("p_id" "uuid", "p_name" "text", "p_url" "text", "p_format" "webhooks"."format", "p_events" "webhooks"."event"[], "p_enabled" boolean, "p_bearer_token" "text", "p_headers" "jsonb") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "webhooks"."rotate_signing_secret"("p_id" "uuid") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "webhooks"."send_test"("p_id" "uuid") FROM PUBLIC, "anon";

GRANT EXECUTE ON FUNCTION "webhooks"."valid_url"("url" "text") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "webhooks"."valid_header"("name" "text", "value" "text") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "webhooks"."valid_headers"("names" "text"[], "vals" "text"[]) TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "webhooks"."can_use"("p_user" "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "webhooks"."enqueue"("p_event" "webhooks"."event", "p_payload" "jsonb", "p_user" "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "webhooks"."claim_deliveries"("p_limit" integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "webhooks"."finish_delivery"("p_id" "uuid", "p_status" integer, "p_error" "text", "p_retry" boolean) TO "service_role";
GRANT EXECUTE ON FUNCTION "webhooks"."delete_old_deliveries"() TO "service_role";
GRANT EXECUTE ON FUNCTION "webhooks"."save_endpoint"("p_id" "uuid", "p_name" "text", "p_url" "text", "p_format" "webhooks"."format", "p_events" "webhooks"."event"[], "p_enabled" boolean, "p_bearer_token" "text", "p_headers" "jsonb") TO "authenticated";
GRANT EXECUTE ON FUNCTION "webhooks"."rotate_signing_secret"("p_id" "uuid") TO "authenticated";
GRANT EXECUTE ON FUNCTION "webhooks"."send_test"("p_id" "uuid") TO "authenticated";
