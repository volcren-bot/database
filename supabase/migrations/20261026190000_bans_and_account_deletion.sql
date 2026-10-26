-- Bans and self-service account deletion.
--
-- Bans: administrators ban and unban accounts from the admin page (profiles.set_banned, which
-- records every change in profiles.bans). A banned account's running scripts end, and it can't
-- start scripts or publish revisions, through the site or a deploy token. The webapp also sets
-- the Auth ban, which blocks sign-in and session refresh.
--
-- Deletion: users delete their own account from the account page (the webapp deletes the auth
-- user). Before the profile goes, its running scripts are ended and charged while the balance
-- still exists (tr_profiles_pre_delete).

ALTER TABLE "profiles"."profiles" ADD COLUMN "banned_at" timestamp with time zone;

COMMENT ON COLUMN "profiles"."profiles"."banned_at" IS 'Set while the account is banned. Only profiles.set_banned writes it.';

CREATE TABLE "profiles"."bans" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "admin_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "banned" boolean NOT NULL,
    "reason" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bans_reason_check" CHECK ("reason" = btrim("reason") AND char_length("reason") BETWEEN 1 AND 500)
);

ALTER TABLE ONLY "profiles"."bans"
    ADD CONSTRAINT "bans_pkey" PRIMARY KEY ("id");

ALTER TABLE "profiles"."bans" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "profiles"."bans" FROM "anon", "authenticated", "service_role";
GRANT SELECT ON TABLE "profiles"."bans" TO "service_role";

CREATE TRIGGER "tr_bans_immutable" BEFORE UPDATE OR DELETE ON "profiles"."bans" FOR EACH ROW EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();

CREATE TRIGGER "tr_bans_truncate" BEFORE TRUNCATE ON "profiles"."bans" FOR EACH STATEMENT EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();

CREATE OR REPLACE FUNCTION "profiles"."is_banned"("user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT EXISTS (SELECT 1 FROM profiles.profiles p WHERE p.id = user_id AND p.banned_at IS NOT NULL);
$$;

REVOKE ALL ON FUNCTION "profiles"."is_banned"("user_id" "uuid") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "profiles"."is_banned"("user_id" "uuid") TO "service_role";

CREATE OR REPLACE FUNCTION "payments"."end_user_sessions"("p_user" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_id uuid;
  v_count integer := 0;
BEGIN
  FOR v_id IN
    SELECT id FROM payments.sessions WHERE user_id = p_user AND ended_at IS NULL
  LOOP
    PERFORM payments.end_session(v_id, 'stopped');
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION "payments"."end_user_sessions"("uuid") FROM PUBLIC, "anon", "authenticated";

CREATE OR REPLACE FUNCTION "profiles"."set_banned"("p_admin" "uuid", "p_user" "uuid", "p_banned" boolean, "p_reason" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF p_admin IS NULL OR NOT profiles.is_role(p_admin, 'administrator') THEN
    RAISE EXCEPTION 'only administrators can ban' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_banned IS NULL THEN
    RAISE EXCEPTION 'p_banned must not be null';
  END IF;

  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'a reason is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles.profiles WHERE id = p_user) THEN
    RAISE EXCEPTION 'user % not found', p_user USING ERRCODE = 'no_data_found';
  END IF;

  IF profiles.min_role(p_user, 'administrator') THEN
    RAISE EXCEPTION 'administrators cannot be banned' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE profiles.profiles SET banned_at = CASE WHEN p_banned THEN now() END
  WHERE id = p_user AND (banned_at IS NOT NULL) <> p_banned;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  INSERT INTO profiles.bans (admin_id, user_id, banned, reason) VALUES (p_admin, p_user, p_banned, btrim(p_reason));

  IF p_banned THEN
    PERFORM payments.end_user_sessions(p_user);
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION "profiles"."set_banned"("p_admin" "uuid", "p_user" "uuid", "p_banned" boolean, "p_reason" "text") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "profiles"."set_banned"("p_admin" "uuid", "p_user" "uuid", "p_banned" boolean, "p_reason" "text") TO "service_role";

CREATE OR REPLACE FUNCTION "payments"."tr_profiles_pre_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  PERFORM payments.end_user_sessions(OLD.id);
  RETURN OLD;
END;
$$;

REVOKE ALL ON FUNCTION "payments"."tr_profiles_pre_delete"() FROM PUBLIC, "anon", "authenticated";

CREATE TRIGGER "tr_profiles_pre_delete" BEFORE DELETE ON "profiles"."profiles" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_profiles_pre_delete"();

-- Banned users can't start sessions, publish revisions or use their deploy tokens

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
  IF profiles.is_banned(p_user) THEN
    RAISE EXCEPTION 'account banned' USING ERRCODE = 'insufficient_privilege';
  END IF;

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

CREATE OR REPLACE FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_version scripts.versions;
  v_file text;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND (auth.uid() IS NULL OR profiles.is_banned(auth.uid()) OR NOT (
    scripts.is_author(auth.uid(), script_id) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  )) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_version FROM scripts.versions v
  WHERE v.id = script_id AND v.revision = publish_version.revision
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'revision % of script % not found', revision, script_id;
  END IF;

  IF v_version.status <> 'pending' THEN
    RAISE EXCEPTION 'revision % is %, only a pending revision can be published', revision, v_version.status;
  END IF;

  FOREACH v_file IN ARRAY v_version.files LOOP
    IF NOT EXISTS (
      SELECT 1 FROM storage.objects o
      WHERE o.bucket_id = 'scripts'
        AND o.name = script_id::text || '/' || lpad(revision::text, 9, '0') || '/' || v_file
    ) THEN
      RAISE EXCEPTION 'file % of revision % is not uploaded', v_file, revision;
    END IF;
  END LOOP;

  UPDATE scripts.versions v SET status = 'live', published_at = now()
  WHERE v.id = script_id AND v.revision = publish_version.revision;

  UPDATE scripts.protected p SET revision = publish_version.revision, updated_at = now()
  WHERE p.id = script_id;
END;
$$;

CREATE OR REPLACE FUNCTION "scripts"."use_deploy_token"("p_script" "uuid", "p_token_hash" "text") RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_id uuid;
BEGIN
  UPDATE scripts.deploy_tokens t SET last_used_at = now()
  WHERE t.script_id = p_script AND t.token_hash = p_token_hash
    AND (scripts.is_author(t.created_by, t.script_id) OR profiles.min_role(t.created_by, 'moderator'::profiles.roles))
    AND NOT profiles.is_banned(t.created_by)
  RETURNING t.id INTO v_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid deploy token' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN v_id;
END;
$$;
