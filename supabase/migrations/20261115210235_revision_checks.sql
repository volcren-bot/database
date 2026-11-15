SET local check_function_bodies = off;

ALTER TABLE "scripts"."protected"
  ADD COLUMN "broken" boolean NOT NULL DEFAULT false;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "checked_lib" text;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "checked_host" integer;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "checked_at" timestamp WITH time zone;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "problems" jsonb;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "requires_host" integer;

CREATE OR REPLACE FUNCTION scripts.can_access (
  accesser_id uuid,
  script_id   uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
      WITH viewer AS (
              SELECT role FROM profiles.profiles WHERE id = accesser_id
      ),
      script AS (
              SELECT p.author, p.revision, p.broken, m.type, m.stage, m.price, s.published,
                     a.role AS author_role, a.banned_at IS NOT NULL AS author_banned,
                     EXISTS (SELECT 1 FROM scripts.grants g WHERE g.script_id = s.id AND g.user_id = accesser_id) AS granted
              FROM scripts.scripts s
              JOIN scripts.metadata m ON m.id = s.id
              JOIN scripts.protected p ON p.id = s.id
              JOIN profiles.profiles a ON a.id = p.author
              WHERE s.id = script_id
      )
      SELECT
              (accesser_id IS NOT DISTINCT FROM auth.uid() OR COALESCE(auth.role(), 'service_role') = 'service_role')
              AND COALESCE((
                      SELECT
                              sc.revision > 0
                              AND (NOT sc.author_banned OR COALESCE(v.role >= 'moderator'::profiles.roles, false))
                              AND (NOT sc.broken OR sc.author = accesser_id OR COALESCE(v.role >= 'moderator'::profiles.roles, false))
                              AND (
                              sc.author = accesser_id
                              OR v.role >= 'moderator'::profiles.roles
                              OR sc.granted
                              OR (
                                      CASE
                                              WHEN sc.author_role < 'scripter'::profiles.roles THEN v.role >= 'tester'::profiles.roles
                                              ELSE (
                                                      CASE sc.stage
                                                              WHEN 'alpha'::scripts.stage THEN v.role >= 'tester'::profiles.roles
                                                              WHEN 'beta'::scripts.stage THEN sc.published
                                                              WHEN 'stable'::scripts.stage THEN sc.published
                                                              ELSE false
                                                      END
                                                      AND (
                                                              sc.type <> 'premium'::scripts.type
                                                              OR v.role >= 'tester'::profiles.roles
                                                              OR COALESCE((SELECT a.microcredits FROM payments.accounts a WHERE a.user_id = accesser_id), 0) >= payments.required_balance(sc.price)
                                                      )
                                              )
                                      END
                              )
                              )
                      FROM script sc
                      LEFT JOIN viewer v ON true
              ), false);
$function$;

CREATE OR REPLACE FUNCTION scripts.can_view (
  viewer_id uuid,
  script_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
      SELECT COALESCE((
        SELECT
          CASE
            WHEN COALESCE(v.role >= 'moderator'::profiles.roles, false) THEN true
            WHEN a.banned_at IS NOT NULL THEN false
            WHEN p.author = viewer_id THEN true
            WHEN p.broken THEN false
            WHEN EXISTS (SELECT 1 FROM scripts.grants g WHERE g.script_id = s.id AND g.user_id = viewer_id) THEN true
            WHEN a.role < 'scripter'::profiles.roles THEN COALESCE(v.role >= 'tester'::profiles.roles, false)
            ELSE
              p.revision > 0
              AND CASE m.stage
                    WHEN 'archived'::scripts.stage THEN false
                    WHEN 'prototype'::scripts.stage THEN false
                    WHEN 'alpha'::scripts.stage THEN COALESCE(v.role >= 'tester'::profiles.roles, false)
                    ELSE s.published
                  END
          END
        FROM scripts.scripts s
        LEFT JOIN scripts.protected p ON p.id = s.id
        LEFT JOIN scripts.metadata m ON m.id = s.id
        LEFT JOIN profiles.profiles a ON a.id = p.author
        LEFT JOIN profiles.profiles v ON v.id = viewer_id
        WHERE s.id = script_id
      ), false);
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

  IF v_version.checked_lib IS NULL OR v_version.problems IS NOT NULL THEN
    RAISE EXCEPTION 'revision % of script % has not passed the script check', revision, script_id USING ERRCODE = 'check_violation';
  END IF;

  -- The real sizes of a community author's files have to fit their storage, whatever was declared
  IF scripts.author_is_community(script_id) THEN
    SELECT p.author INTO v_author FROM scripts.protected p WHERE p.id = script_id;

    PERFORM pg_advisory_xact_lock(hashtext('scripts.storage.' || v_author::text));

    IF scripts.storage_used(v_author, false) > (SELECT c.max_community_bytes FROM scripts.config c) THEN
      RAISE EXCEPTION 'community storage limit reached' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  UPDATE scripts.versions v SET status = 'live', published_at = now(), requires_host = v_version.checked_host
  WHERE v.id = script_id AND v.revision = publish_version.revision;

  UPDATE scripts.protected p SET revision = publish_version.revision, updated_at = now(),
    queueable = COALESCE((v_version.manifest ->> 'queueable')::boolean, false), broken = false
  WHERE p.id = script_id;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.record_check (
  p_script   uuid,
  p_revision integer,
  p_lib      text,
  p_host     integer,
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
BEGIN
  IF p_lib IS NULL OR p_lib !~ '^[0-9A-Za-z.-]{1,64}$' OR p_host IS NULL OR p_host < 0 THEN
    RAISE EXCEPTION 'a check names the lib version and its host api' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE scripts.versions v
  SET checked_lib = p_lib, checked_host = p_host, checked_at = now(), problems = v_problems
  WHERE v.id = p_script AND v.revision = p_revision
    AND v.status IN ('pending'::scripts.version_status, 'live'::scripts.version_status);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no pending or live revision % of script %', p_revision, p_script USING ERRCODE = 'no_data_found';
  END IF;

  UPDATE scripts.protected p SET broken = v_problems IS NOT NULL
  WHERE p.id = p_script AND p.revision = p_revision;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.tr_versions_pre_insert()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_author uuid;
BEGIN
  UPDATE scripts.protected
  SET last_revision = last_revision + 1
  WHERE id = NEW.id
  RETURNING last_revision, author INTO NEW.revision, v_author;

  NEW.status := 'pending';
  NEW.published_at := NULL;

  -- A single file is the entry. With several, the uploader has to say which one.
  IF NEW.entry IS NULL AND cardinality(NEW.files) = 1 THEN
    NEW.entry := NEW.files[1];
  ELSIF NEW.entry IS NULL THEN
    RAISE EXCEPTION 'a revision with several files needs an entry file' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- A community author declares each file's size; publish_version rechecks the real ones
  IF scripts.author_is_community(NEW.id) THEN
    IF cardinality(NEW.sizes) <> cardinality(NEW.files) THEN
      RAISE EXCEPTION 'every file needs its size' USING ERRCODE = 'check_violation';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('scripts.storage.' || v_author::text));

    IF scripts.storage_used(v_author) + (SELECT COALESCE(sum(z), 0) FROM unnest(NEW.sizes) z) > (SELECT c.max_community_bytes FROM scripts.config c) THEN
      RAISE EXCEPTION 'community storage limit reached' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

ALTER TABLE "scripts"."versions"
  ADD CONSTRAINT "versions_check_complete"
    CHECK ((((checked_lib IS NULL) = (checked_host IS NULL)) AND ((checked_lib IS NULL) = (checked_at IS NULL)) AND ((problems IS NULL) OR (checked_lib IS NOT NULL))));

ALTER TABLE "scripts"."versions"
  ADD CONSTRAINT "versions_problems_check"
    CHECK (((problems IS NULL) OR ((jsonb_typeof(problems) = 'array'::text) AND (jsonb_array_length(problems) > 0) AND (pg_column_size(problems) <= 65536))));

COMMENT ON COLUMN "scripts"."protected"."broken" IS 'The live revision failed the script check against the newest lib (versions.problems). Copied here by record_check so listings can read it; only the author and moderator+ see a broken script.';

COMMENT ON COLUMN "scripts"."versions"."checked_lib" IS 'The lib version the revision was last type-checked against, and checked_host that lib''s requires_host. Set only by record_check (the api service).';

COMMENT ON COLUMN "scripts"."versions"."problems" IS 'What the last check found, as [{ file, line, column, message }]; null when it passed. A pending revision with problems can''t be published.';

COMMENT ON COLUMN "scripts"."versions"."requires_host" IS 'The host api of the lib the revision passed when it went live, set by publish_version. Later checks don''t change it, so a loader whose injector is older refuses only revisions published against a newer lib.';

REVOKE ALL ON FUNCTION "scripts"."record_check"(uuid, integer, text, integer, jsonb) FROM PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "scripts"."record_check"(uuid, integer, text, integer, jsonb) TO "postgres", "service_role";
