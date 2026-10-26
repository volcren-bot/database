-- Deploy tokens: CI (GitHub Actions) publishes revisions of one script through the webapp's
-- /api/scripts/<id>/revisions endpoint instead of signing in with a password. The endpoint checks
-- the token with use_deploy_token and then works as service_role, so publish_version and
-- discard_version now accept service_role too.

CREATE TABLE "scripts"."deploy_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "script_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "token_hash" "text" NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_used_at" timestamp with time zone,
    CONSTRAINT "deploy_tokens_name_check" CHECK ("name" = btrim("name") AND char_length("name") BETWEEN 1 AND 64),
    CONSTRAINT "deploy_tokens_token_hash_check" CHECK ("token_hash" ~ '^[0-9a-f]{64}$')
);

ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_token_hash_key" UNIQUE ("token_hash");

ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_script_id_fkey" FOREIGN KEY ("script_id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

CREATE INDEX "deploy_tokens_script_id_idx" ON "scripts"."deploy_tokens" USING "btree" ("script_id");

CREATE OR REPLACE FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_version scripts.versions;
  v_file text;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND (auth.uid() IS NULL OR NOT (
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

CREATE OR REPLACE FUNCTION "scripts"."discard_version"("script_id" "uuid", "revision" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND (auth.uid() IS NULL OR NOT (
    scripts.is_author(auth.uid(), script_id) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  )) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE scripts.versions v SET status = 'discarded'
  WHERE v.id = script_id AND v.revision = discard_version.revision AND v.status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no pending revision % of script %', revision, script_id;
  END IF;
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
  RETURNING t.id INTO v_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid deploy token' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN v_id;
END;
$$;

ALTER TABLE "scripts"."deploy_tokens" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for AUTHOR" ON "scripts"."deploy_tokens" FOR SELECT TO "authenticated"
    USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

CREATE POLICY "INSERT for AUTHOR" ON "scripts"."deploy_tokens" FOR INSERT TO "authenticated"
    WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

CREATE POLICY "DELETE for AUTHOR" ON "scripts"."deploy_tokens" FOR DELETE TO "authenticated"
    USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

REVOKE ALL ON TABLE "scripts"."deploy_tokens" FROM "anon", "authenticated";
GRANT SELECT ("id", "script_id", "name", "created_by", "created_at", "last_used_at") ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT INSERT ("script_id", "name", "token_hash") ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT DELETE ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT ALL ON TABLE "scripts"."deploy_tokens" TO "service_role";

REVOKE ALL ON FUNCTION "scripts"."use_deploy_token"("p_script" "uuid", "p_token_hash" "text") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "scripts"."use_deploy_token"("p_script" "uuid", "p_token_hash" "text") TO "service_role";
