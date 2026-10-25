-- Charge every minute: the heartbeat charges each elapsed minute, so payments.config.batch_minutes
-- is gone and min_balance_batches becomes min_balance_minutes. One formula for the minimum balance
-- (payments.required_balance) is used by scripts.can_access, start_session and heartbeat_session.
-- Also: deleted accounts no longer break charging, end_stale_sessions isolates and re-checks each
-- session, can_upload uses auth.uid(), and the imgs policies no longer error on a non-uuid folder.

ALTER TABLE payments.config DROP CONSTRAINT config_batch_check;
ALTER TABLE payments.config DROP COLUMN batch_minutes;
ALTER TABLE payments.config RENAME COLUMN min_balance_batches TO min_balance_minutes;
ALTER TABLE payments.config ADD CONSTRAINT config_check CHECK (session_timeout_minutes > 0 AND min_balance_minutes > 0);
COMMENT ON COLUMN payments.config.min_balance_minutes IS 'A session needs a balance covering this many minutes at its price to start and to keep running (see payments.required_balance).';

CREATE OR REPLACE FUNCTION "payments"."required_balance"("p_price" bigint) RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT p_price * min_balance_minutes FROM payments.config;
$$;

CREATE OR REPLACE FUNCTION "payments"."charge_session"("p_session" "uuid", "p_minutes" integer) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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

  -- a deleted user can't pay: the whole cost is unpaid
  IF NOT FOUND THEN
    UPDATE payments.sessions SET unpaid = unpaid + v_cost WHERE id = p_session;
    RETURN 0;
  END IF;

  v_charged := LEAST(v_cost, v_available);

  IF v_charged < v_cost THEN
    UPDATE payments.sessions SET unpaid = unpaid + (v_cost - v_charged) WHERE id = p_session;
  END IF;

  IF v_charged > 0 THEN
    PERFORM payments.post_credits(v_session.user_id, 'usage', -v_charged, NULL, v_session.script_id, p_minutes, NULL, p_session);

    v_share := v_charged * (10000 - (SELECT platform_fee_bps FROM payments.config)) / 10000;

    -- a deleted author has no account: the platform keeps the share
    IF v_share > 0 AND EXISTS (SELECT 1 FROM payments.accounts WHERE user_id = v_session.author_id) THEN
      PERFORM payments.post_earnings(v_session.author_id, 'sale', v_share, v_session.script_id, p_minutes, NULL, p_session);
    END IF;
  END IF;

  RETURN v_charged;
END;
$$;

CREATE OR REPLACE FUNCTION "payments"."start_session"("p_user" "uuid", "p_script" "uuid") RETURNS TABLE ("session_id" "uuid", "revision" integer, "files" "text"[])
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_author uuid;
  v_revision integer;
  v_listed_price bigint;
  v_price bigint;
  v_files text[];
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

  IF v_price > 0 AND COALESCE((SELECT a.credits FROM payments.accounts a WHERE a.user_id = p_user), 0)
                     < payments.required_balance(v_price) THEN
    RAISE EXCEPTION 'insufficient credits' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO payments.sessions AS s (user_id, script_id, author_id, revision, price)
  VALUES (p_user, p_script, v_author, v_revision, v_price)
  RETURNING s.id INTO v_id;

  RETURN QUERY SELECT v_id, v_revision, v_files;
END;
$$;

CREATE OR REPLACE FUNCTION "payments"."heartbeat_session"("p_session" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_session payments.sessions;
  v_minutes integer;
  v_balance bigint;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session FOR UPDATE;

  IF NOT FOUND OR v_session.ended_at IS NOT NULL THEN
    RETURN false;
  END IF;

  UPDATE payments.sessions SET last_seen = now() WHERE id = p_session;

  v_minutes := floor(extract(epoch FROM (now() - v_session.charged_until)) / 60)::integer;

  IF v_minutes >= 1 THEN
    PERFORM payments.charge_session(p_session, v_minutes);

    UPDATE payments.sessions SET charged_until = charged_until + make_interval(mins => v_minutes) WHERE id = p_session;
  END IF;

  IF v_session.price > 0 THEN
    SELECT credits INTO v_balance FROM payments.accounts WHERE user_id = v_session.user_id;

    IF COALESCE(v_balance, 0) < payments.required_balance(v_session.price) THEN
      PERFORM payments.end_session(p_session, 'insufficient_credits');
      RETURN false;
    END IF;
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION "payments"."end_stale_sessions"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_id uuid;
  v_timeout interval := make_interval(mins => (SELECT session_timeout_minutes FROM payments.config));
  v_count integer := 0;
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

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION "scripts"."safe_uuid"("value" "text") RETURNS "uuid"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT CASE
    WHEN value ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN value::uuid
  END;
$$;

CREATE OR REPLACE FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
      WITH viewer AS (
              SELECT role FROM profiles.profiles WHERE id = accesser_id
      ),
      script AS (
              SELECT p.author, p.revision, m.type, m.stage, m.price, s.published
              FROM scripts.scripts s
              JOIN scripts.metadata m ON m.id = s.id
              JOIN scripts.protected p ON p.id = s.id
              WHERE s.id = script_id
      )
      SELECT
              (accesser_id IS NOT DISTINCT FROM auth.uid() OR COALESCE(auth.role(), 'service_role') = 'service_role')
              AND COALESCE((
                      SELECT
                              sc.revision > 0
                              AND (
                              sc.author = accesser_id
                              OR v.role >= 'moderator'::profiles.roles
                              OR (
                                      CASE sc.stage
                                              WHEN 'alpha'::scripts.stage THEN v.role >= 'tester'::profiles.roles
                                              WHEN 'beta'::scripts.stage THEN sc.published
                                              WHEN 'stable'::scripts.stage THEN sc.published
                                              ELSE false
                                      END
                                      AND (
                                              sc.type <> 'premium'::scripts.type
                                              OR v.role >= 'tester'::profiles.roles
                                              OR COALESCE((SELECT a.credits FROM payments.accounts a WHERE a.user_id = accesser_id), 0) >= payments.required_balance(sc.price)
                                      )
                              )
                              )
                      FROM script sc
                      LEFT JOIN viewer v ON true
              ), false);
$$;

REVOKE ALL ON FUNCTION payments.required_balance(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION payments.required_balance(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION scripts.safe_uuid(text) TO anon, authenticated, service_role;

-- can_upload(user_id, object_name) -> can_upload(object_name)
DROP POLICY "scripts INSERT for author" ON storage.objects;
DROP POLICY "imgs INSERT for author" ON storage.objects;
DROP POLICY "imgs UPDATE for author" ON storage.objects;
DROP FUNCTION scripts.can_upload(uuid, text);

CREATE OR REPLACE FUNCTION "scripts"."can_upload"("object_name" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM scripts.versions v
    WHERE v.id = scripts.safe_uuid(split_part(object_name, '/', 1))
      AND v.status = 'pending'::scripts.version_status
      AND starts_with(object_name, v.id::text || '/' || lpad(v.revision::text, 9, '0') || '/')
      AND substr(object_name, length(v.id::text || '/' || lpad(v.revision::text, 9, '0') || '/') + 1) = ANY (v.files)
      AND (
        scripts.is_author(auth.uid(), v.id)
        OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
      )
  );
$$;

REVOKE ALL ON FUNCTION scripts.can_upload(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION scripts.can_upload(text) TO authenticated, service_role;

CREATE POLICY "scripts INSERT for author" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'scripts'::"text") AND "scripts"."can_upload"("name")));

CREATE POLICY "imgs INSERT for author" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "imgs UPDATE for author" ON "storage"."objects" FOR UPDATE USING ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")))) WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

