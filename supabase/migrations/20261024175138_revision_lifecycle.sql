SET local check_function_bodies = off;

DROP POLICY "SELECT for ALLOWED" ON "scripts"."versions";

DROP POLICY "scripts INSERT for author" ON "storage"."objects";

DROP TRIGGER "wh-scripts.versions" ON "scripts"."versions";

ALTER TABLE "scripts"."protected"
  ADD COLUMN "last_revision" integer NOT NULL DEFAULT 0;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "created_at" timestamp WITH time zone NOT NULL DEFAULT now();

ALTER TABLE "scripts"."versions"
  ADD COLUMN "published_at" timestamp WITH time zone;

CREATE TYPE "scripts"."version_status" AS ENUM (
  'pending',
  'live',
  'discarded'
);

ALTER TABLE "scripts"."versions"
  ADD COLUMN "status" scripts.version_status NOT NULL DEFAULT 'pending'::scripts.version_status;

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
                                              OR COALESCE((SELECT a.credits FROM payments.accounts a WHERE a.user_id = accesser_id), 0) >= sc.price
                                      )
                              )
                              )
                      FROM script sc
                      LEFT JOIN viewer v ON true
              ), false);
$function$;

CREATE OR REPLACE FUNCTION scripts.can_upload (
  user_id     uuid,
  object_name text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM scripts.versions v
    WHERE v.id = CASE
                   WHEN split_part(object_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   THEN split_part(object_name, '/', 1)::uuid
                 END
      AND v.status = 'pending'::scripts.version_status
      AND starts_with(object_name, v.id::text || '/' || lpad(v.revision::text, 9, '0') || '/')
      AND substr(object_name, length(v.id::text || '/' || lpad(v.revision::text, 9, '0') || '/') + 1) = ANY (v.files)
      AND (
        scripts.is_author(user_id, v.id)
        OR profiles.min_role(user_id, 'moderator'::profiles.roles)
      )
  );
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
          p.author = viewer_id
          OR COALESCE(v.role >= 'moderator'::profiles.roles, false)
          OR (
            p.revision > 0
            AND CASE m.stage
                  WHEN 'archived'::scripts.stage THEN false
                  WHEN 'prototype'::scripts.stage THEN false
                  WHEN 'alpha'::scripts.stage THEN COALESCE(v.role >= 'tester'::profiles.roles, false)
                  ELSE s.published
                END
          )
        FROM scripts.scripts s
        LEFT JOIN scripts.protected p ON p.id = s.id
        LEFT JOIN scripts.metadata m ON m.id = s.id
        LEFT JOIN profiles.profiles v ON v.id = viewer_id
        WHERE s.id = script_id
      ), false);
$function$;

CREATE OR REPLACE FUNCTION scripts.discard_version (
  script_id uuid,
  revision  integer
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT (
    scripts.is_author(auth.uid(), script_id) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  ) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE scripts.versions v SET status = 'discarded'
  WHERE v.id = script_id AND v.revision = discard_version.revision AND v.status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no pending revision % of script %', revision, script_id;
  END IF;
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
BEGIN
  IF auth.uid() IS NULL OR NOT (
    scripts.is_author(auth.uid(), script_id) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  ) THEN
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
$function$;

CREATE OR REPLACE FUNCTION scripts.tr_versions_pre_insert()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  UPDATE scripts.protected
  SET last_revision = last_revision + 1
  WHERE id = NEW.id
  RETURNING last_revision INTO NEW.revision;

  NEW.status := 'pending';
  NEW.published_at := NULL;

  RETURN NEW;
END;
$function$;

CREATE UNIQUE INDEX versions_one_pending_idx ON scripts.versions USING btree (id)
  WHERE (status = 'pending'::scripts.version_status);

CREATE TRIGGER "wh-scripts.versions"
  AFTER UPDATE OF status ON scripts.versions
  FOR EACH ROW
  WHEN ((new.status = 'live'::scripts.version_status))
  EXECUTE FUNCTION public.webhook();

CREATE POLICY "SELECT for AUTHOR" ON "scripts"."versions"
  FOR SELECT
  TO PUBLIC
  USING ((scripts.is_author(profiles.uid(), id) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles)));

CREATE POLICY "scripts INSERT for author" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((bucket_id = 'scripts'::text) AND scripts.can_upload(profiles.uid(), name)));

COMMENT ON COLUMN "scripts"."protected"."last_revision" IS 'Revision allocator. Counts pending and discarded revisions too.';

COMMENT ON COLUMN "scripts"."protected"."revision" IS 'The live revision. 0 means none yet, and the script can''t be run.';

COMMENT ON TYPE "scripts"."version_status" IS 'Revision lifecycle';

REVOKE ALL ON FUNCTION "scripts"."can_upload"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."can_upload"(uuid, text) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."discard_version"(uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."discard_version"(uuid, integer) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."publish_version"(uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."publish_version"(uuid, integer) TO "authenticated", "postgres", "service_role";

GRANT USAGE ON TYPE "scripts"."version_status" TO "postgres";
