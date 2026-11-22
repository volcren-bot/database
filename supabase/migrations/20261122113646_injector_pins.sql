-- Revisions pin the client release they were checked against instead of a lib and its host api:
-- the SDK ships inside the injector, so the loader runs each revision with the injector.exe it names.
-- Retiring a release (retire_injector) makes every revision pinned to it unsupported.
SET local check_function_bodies = off;

ALTER TABLE "scripts"."versions"
  DROP CONSTRAINT "versions_check_complete";

DROP FUNCTION "payments"."start_session"(uuid, uuid);

DROP FUNCTION "scripts"."record_check"(uuid, integer, text, integer, jsonb);

ALTER TABLE "scripts"."versions"
  DROP COLUMN "checked_host";

ALTER TABLE "scripts"."versions"
  DROP COLUMN "checked_lib";

ALTER TABLE "scripts"."versions"
  DROP COLUMN "requires_host";

CREATE TABLE "scripts"."injectors" (
  "version"    text                     NOT NULL,
  "build"      bigint                   NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  "retired_at" timestamp with time zone,
  CONSTRAINT "injectors_build_check" CHECK ((build > 0)),
  CONSTRAINT "injectors_pkey" PRIMARY KEY (VERSION),
  CONSTRAINT "injectors_version_check" CHECK ((version ~ '^[0-9A-Za-z.-]{1,64}$'::text))
);

ALTER TABLE "scripts"."injectors"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "checked_injector" text;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "injector" text;

CREATE OR REPLACE FUNCTION payments.start_session (
  p_user   uuid,
  p_script uuid
)
  RETURNS TABLE (
    session_id uuid,
    revision   integer,
    files      text[],
    entry      text,
    rank       integer,
    fee        bigint,
    injector   text
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
  v_entry text;
  v_injector text;
  v_id uuid;
  v_rank integer;
  v_fee bigint;
  v_required bigint;
BEGIN
  IF profiles.is_banned(p_user) THEN
    RAISE EXCEPTION 'account banned' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT scripts.can_access(p_user, p_script) OR scripts.author_is_banned(p_script) THEN
    RAISE EXCEPTION 'script not accessible' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT p.author, p.revision, m.price INTO v_author, v_revision, v_listed_price
  FROM scripts.protected p
  JOIN scripts.metadata m ON m.id = p.id
  WHERE p.id = p_script;

  SELECT v.files, v.entry, v.injector INTO v_files, v_entry, v_injector FROM scripts.versions v
  WHERE v.id = p_script AND v.revision = v_revision AND v.status = 'live'::scripts.version_status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'script % has no live revision', p_script;
  END IF;

  IF v_injector IS NULL OR EXISTS (SELECT 1 FROM scripts.injectors i WHERE i.version = v_injector AND i.retired_at IS NOT NULL) THEN
    RAISE EXCEPTION 'the live revision of script % runs on an injector that is no longer supported', p_script USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  v_price := CASE
    WHEN v_author = p_user OR profiles.min_role(p_user, 'tester'::profiles.roles) OR scripts.has_grant(p_user, p_script) THEN 0
    ELSE v_listed_price
  END;

  -- the new session ranks after every open one, and an extra instance pays the fee even on a free script
  SELECT count(*)::integer INTO v_rank FROM payments.sessions s WHERE s.user_id = p_user AND s.ended_at IS NULL;
  v_fee := payments.session_fee(p_user, v_rank);
  v_required := payments.required_balance(v_price, v_fee);

  IF v_required > 0 AND COALESCE((SELECT a.microcredits FROM payments.accounts a WHERE a.user_id = p_user), 0) < v_required THEN
    RAISE EXCEPTION 'insufficient credits' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO payments.sessions AS s (user_id, script_id, author_id, revision, price)
  VALUES (p_user, p_script, v_author, v_revision, v_price)
  RETURNING s.id INTO v_id;

  RETURN QUERY SELECT v_id, v_revision, v_files, v_entry, v_rank, v_fee, v_injector;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.publish_version (
  script_id uuid,
  revision  integer
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_version scripts.versions;
  v_file text;
  v_author uuid;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND (auth.uid() IS NULL OR profiles.is_banned(auth.uid()) OR NOT (
    scripts.is_author(auth.uid(), script_id) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  ) OR NOT profiles.has_accepted_terms(auth.uid())) THEN
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

  -- Every revision is stored encrypted (set_version_key)
  IF NOT EXISTS (SELECT 1 FROM scripts.version_keys k WHERE k.id = script_id AND k.revision = publish_version.revision) THEN
    RAISE EXCEPTION 'revision % of script % has no encryption key', revision, script_id;
  END IF;

  IF v_version.checked_injector IS NULL OR v_version.problems IS NOT NULL THEN
    RAISE EXCEPTION 'revision % of script % has not passed the script check', revision, script_id USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (SELECT 1 FROM scripts.injectors i WHERE i.version = v_version.checked_injector AND i.retired_at IS NOT NULL) THEN
    RAISE EXCEPTION 'revision % of script % was checked against retired injector %', revision, script_id, v_version.checked_injector USING ERRCODE = 'check_violation';
  END IF;

  -- The real sizes of a community author's files have to fit their storage, whatever was declared
  IF scripts.author_is_community(script_id) THEN
    SELECT p.author INTO v_author FROM scripts.protected p WHERE p.id = script_id;

    PERFORM pg_advisory_xact_lock(hashtext('scripts.storage.' || v_author::text));

    IF scripts.storage_used(v_author, false) > (SELECT c.max_community_bytes FROM scripts.config c) THEN
      RAISE EXCEPTION 'community storage limit reached' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  UPDATE scripts.versions v SET status = 'live', published_at = now(), injector = v_version.checked_injector
  WHERE v.id = script_id AND v.revision = publish_version.revision;

  UPDATE scripts.protected p SET revision = publish_version.revision, updated_at = now(),
    queueable = COALESCE((v_version.manifest ->> 'queueable')::boolean, false), broken = false
  WHERE p.id = script_id;
END;
$function$;

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
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.register_injector (
  p_version text,
  p_build   bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  INSERT INTO scripts.injectors (version, build) VALUES (p_version, p_build)
  ON CONFLICT (version) DO NOTHING;

  IF NOT EXISTS (SELECT 1 FROM scripts.injectors i WHERE i.version = p_version AND i.build = p_build) THEN
    RAISE EXCEPTION 'injector % is registered with another build', p_version USING ERRCODE = 'unique_violation';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.retire_injector (
  p_version text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_broken integer;
BEGIN
  UPDATE scripts.injectors i SET retired_at = COALESCE(i.retired_at, now()) WHERE i.version = p_version;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'injector % is not registered', p_version USING ERRCODE = 'no_data_found';
  END IF;

  UPDATE scripts.protected p SET broken = true
  FROM scripts.versions v
  WHERE v.id = p.id AND v.revision = p.revision AND v.injector = p_version AND NOT p.broken;
  GET DIAGNOSTICS v_broken = ROW_COUNT;

  RETURN v_broken;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.valid_manifest (
  manifest jsonb
)
  RETURNS boolean
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
DECLARE
  v_goals jsonb := COALESCE(manifest -> 'goals', '[]'::jsonb);
  v_settings jsonb := manifest -> 'settings';
  v_goal jsonb;
  v_field jsonb;
BEGIN
  IF manifest IS NULL THEN
    RETURN true;
  END IF;

  IF jsonb_typeof(manifest) <> 'object' OR octet_length(manifest::text) > 65536 THEN
    RETURN false;
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_object_keys(manifest) k WHERE k NOT IN ('queueable', 'goals', 'settings', 'finish_grace_minutes', 'auto_forward')) THEN
    RETURN false;
  END IF;

  IF manifest ? 'queueable' AND jsonb_typeof(manifest -> 'queueable') <> 'boolean' THEN
    RETURN false;
  END IF;

  IF manifest ? 'auto_forward' AND jsonb_typeof(manifest -> 'auto_forward') <> 'boolean' THEN
    RETURN false;
  END IF;

  IF manifest ? 'finish_grace_minutes' THEN
    IF jsonb_typeof(manifest -> 'finish_grace_minutes') <> 'number' THEN
      RETURN false;
    END IF;

    IF (manifest ->> 'finish_grace_minutes')::numeric NOT BETWEEN 1 AND 120
       OR (manifest ->> 'finish_grace_minutes')::numeric % 1 <> 0 THEN
      RETURN false;
    END IF;
  END IF;

  IF jsonb_typeof(v_goals) <> 'array' THEN
    RETURN false;
  END IF;

  IF jsonb_array_length(v_goals) > 16 THEN
    RETURN false;
  END IF;

  FOR v_goal IN SELECT * FROM jsonb_array_elements(v_goals) LOOP
    IF jsonb_typeof(v_goal) <> 'object' THEN
      RETURN false;
    END IF;

    IF (SELECT count(*) FROM jsonb_object_keys(v_goal)) <> 2
       OR jsonb_typeof(v_goal -> 'id') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_goal -> 'label') IS DISTINCT FROM 'string'
       OR v_goal ->> 'id' !~ '^[a-z][a-z0-9_]{0,31}$'
       OR char_length(v_goal ->> 'label') NOT BETWEEN 1 AND 64 THEN
      RETURN false;
    END IF;
  END LOOP;

  IF (SELECT count(DISTINCT g ->> 'id') FROM jsonb_array_elements(v_goals) g) <> jsonb_array_length(v_goals) THEN
    RETURN false;
  END IF;

  IF v_settings IS NOT NULL THEN
    IF jsonb_typeof(v_settings) <> 'object' OR jsonb_typeof(v_settings -> 'fields') IS DISTINCT FROM 'array' THEN
      RETURN false;
    END IF;

    IF jsonb_array_length(v_settings -> 'fields') > 200 THEN
      RETURN false;
    END IF;

    FOR v_field IN SELECT * FROM jsonb_array_elements(v_settings -> 'fields') LOOP
      IF jsonb_typeof(v_field) <> 'object' THEN
        RETURN false;
      END IF;
    END LOOP;
  END IF;

  RETURN true;
END;
$function$;

UPDATE "scripts"."versions" SET "checked_at" = NULL, "problems" = NULL;

ALTER TABLE "scripts"."versions"
  ADD CONSTRAINT "versions_check_complete" CHECK ((((checked_injector IS NULL) = (checked_at IS NULL)) AND ((problems IS NULL) OR (checked_injector IS NOT NULL))));

ALTER TABLE "scripts"."versions"
  ADD CONSTRAINT "versions_checked_injector_fkey" FOREIGN KEY (checked_injector) REFERENCES scripts.injectors(VERSION) ON DELETE RESTRICT;

ALTER TABLE "scripts"."versions"
  ADD CONSTRAINT "versions_injector_fkey" FOREIGN KEY (injector) REFERENCES scripts.injectors(VERSION) ON DELETE RESTRICT;

CREATE POLICY "SELECT for EVERYONE" ON "scripts"."injectors"
  FOR SELECT
  TO PUBLIC
  USING (true);

COMMENT ON COLUMN "scripts"."injectors"."retired_at" IS 'Set by retire_injector once the release can no longer run (an IPC or game-update break). Every revision pinned to it stops being runnable.';

COMMENT ON COLUMN "scripts"."protected"."broken" IS 'The live revision can''t run: it has no injector, or its injector was retired (retire_injector). Cleared when a revision goes live or record_check moves the live one onto a supported injector; only the author and moderator+ see a broken script.';

COMMENT ON COLUMN "scripts"."versions"."checked_injector" IS 'The client release whose SDK the revision was last type-checked against. Set only by record_check (the api service).';

COMMENT ON COLUMN "scripts"."versions"."injector" IS 'The client release the loader runs the revision with. publish_version pins the one it passed; record_check moves a live revision to a newer one it passes, unless its manifest sets auto_forward to false.';

COMMENT ON TABLE "scripts"."injectors" IS 'Client releases (version YYYY.MM.DD-<sha7>, build = commit time) whose injector.exe and SDK revisions are checked against and pinned to. Ordered by build.';

REVOKE ALL ON FUNCTION "payments"."start_session"(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."start_session"(uuid, uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."record_check"(uuid, integer, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."record_check"(uuid, integer, text, jsonb) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."register_injector"(text, bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."register_injector"(text, bigint) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."retire_injector"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."retire_injector"(text) TO "postgres", "service_role";

GRANT SELECT ON TABLE "scripts"."injectors" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "scripts"."injectors" TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."start_session"(uuid, uuid) FROM "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."record_check"(uuid, integer, text, jsonb) FROM "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."register_injector"(text, bigint) FROM "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."retire_injector"(text) FROM "anon", "authenticated";

-- Revisions live before this were checked against a lib, not an injector: none can run until republished
UPDATE "scripts"."protected" p SET "broken" = true
FROM "scripts"."versions" v
WHERE v."id" = p."id" AND v."revision" = p."revision" AND v."injector" IS NULL;
