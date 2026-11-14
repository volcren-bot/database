SET local check_function_bodies = off;

ALTER TABLE "scripts"."protected"
  ADD COLUMN "queueable" boolean NOT NULL DEFAULT false;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "manifest" jsonb;

CREATE OR REPLACE FUNCTION scripts.live_manifest (
  script_id uuid
)
  RETURNS TABLE (
    revision integer,
    manifest jsonb
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT v.revision, v.manifest
  FROM scripts.protected p
  JOIN scripts.versions v ON v.id = p.id AND v.revision = p.revision
  WHERE p.id = live_manifest.script_id
    AND (auth.role() = 'service_role' OR scripts.can_view(profiles.uid(), live_manifest.script_id));
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

  -- The real sizes of a community author's files have to fit their storage, whatever was declared
  IF scripts.author_is_community(script_id) THEN
    SELECT p.author INTO v_author FROM scripts.protected p WHERE p.id = script_id;

    PERFORM pg_advisory_xact_lock(hashtext('scripts.storage.' || v_author::text));

    IF scripts.storage_used(v_author, false) > (SELECT c.max_community_bytes FROM scripts.config c) THEN
      RAISE EXCEPTION 'community storage limit reached' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  UPDATE scripts.versions v SET status = 'live', published_at = now()
  WHERE v.id = script_id AND v.revision = publish_version.revision;

  UPDATE scripts.protected p SET revision = publish_version.revision, updated_at = now(),
    queueable = COALESCE((v_version.manifest ->> 'queueable')::boolean, false)
  WHERE p.id = script_id;
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

  IF EXISTS (SELECT 1 FROM jsonb_object_keys(manifest) k WHERE k NOT IN ('queueable', 'goals', 'settings', 'finish_grace_minutes')) THEN
    RETURN false;
  END IF;

  IF manifest ? 'queueable' AND jsonb_typeof(manifest -> 'queueable') <> 'boolean' THEN
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

REVOKE ALL ON FUNCTION "scripts"."live_manifest"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."live_manifest"(uuid) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."valid_manifest"(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."valid_manifest"(jsonb) TO "authenticated", "postgres", "service_role";

REVOKE ALL ("manifest") ON TABLE "scripts"."versions" FROM "authenticated";

GRANT INSERT ("manifest") ON TABLE "scripts"."versions" TO "authenticated";

ALTER TABLE "scripts"."versions"
  ADD CONSTRAINT "versions_manifest_check" CHECK (scripts.valid_manifest(manifest));
