-- Schema: scripts (rewritten by hand for Volcren)
-- Apply order: public -> profiles -> scripts -> payments -> stats -> info (scripts.can_access reads payments.accounts at call time)
--
-- A script is a set of files (Luau and others) in the `scripts` storage bucket,
-- one folder per revision. Author names/avatars are not copied here: join profiles.profiles.
-- There are no script versions and no Official/Community status.


CREATE SCHEMA IF NOT EXISTS "scripts";

ALTER SCHEMA "scripts" OWNER TO "postgres";

-- Types

CREATE TYPE "scripts"."category" AS ENUM (
    'combat',
    'boss',
    'minigame',
    'moneymaker',
    'tool',
    'magic',
    'prayer',
    'mining',
    'fishing',
    'woodcutting',
    'hunter',
    'farming',
    'cooking',
    'smithing',
    'fletching',
    'firemaking',
    'herblore',
    'crafting',
    'construction',
    'agility',
    'slayer',
    'thieving',
    'runecrafting',
    'sailing'
);


COMMENT ON TYPE "scripts"."category" IS 'Script categories';

-- Order matters: min_stage/max_stage compare with >=/<=
CREATE TYPE "scripts"."stage" AS ENUM (
    'prototype',
    'alpha',
    'beta',
    'stable',
    'archived'
);


COMMENT ON TYPE "scripts"."stage" IS 'Release lifecycle';

CREATE TYPE "scripts"."type" AS ENUM (
    'premium',
    'free'
);


COMMENT ON TYPE "scripts"."type" IS 'Script type';

-- A revision is created pending, its files are uploaded, and it goes live only once every listed file exists.
CREATE TYPE "scripts"."version_status" AS ENUM (
    'pending',
    'live',
    'discarded'
);

COMMENT ON TYPE "scripts"."version_status" IS 'Revision lifecycle';

-- Tables

CREATE TABLE IF NOT EXISTS "scripts"."scripts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "url" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "content" "text" NOT NULL,
    "published" boolean DEFAULT false NOT NULL
);


-- Every slug a script has had. scripts.url is the current one; the rest redirect to it.
-- A slug is never released, so an old link can't end up pointing at someone else's script.
CREATE TABLE IF NOT EXISTS "scripts"."slugs" (
    "slug" "text" NOT NULL,
    "id" "uuid" NOT NULL
);


CREATE TABLE IF NOT EXISTS "scripts"."metadata" (
    "id" "uuid" NOT NULL,
    "type" "scripts"."type" DEFAULT 'free'::"scripts"."type" NOT NULL,
    "categories" "scripts"."category"[] DEFAULT '{}'::"scripts"."category"[] NOT NULL,
    "stage" "scripts"."stage" DEFAULT 'prototype'::"scripts"."stage" NOT NULL,
    "price" bigint DEFAULT 0 NOT NULL,
    CONSTRAINT "metadata_price_check" CHECK (("price" >= 0) AND (("type" = 'free'::"scripts"."type") = ("price" = 0))),
    CONSTRAINT "metadata_price_max_check" CHECK ("price" <= 22)
);

COMMENT ON COLUMN "scripts"."metadata"."price" IS 'Credits (1 credit = 0.01 cent EUR, 10,000 credits = 1 EUR) charged per minute of use. 0 for free scripts, 1 to 22 for premium ones: 22 a minute is about 98 EUR for a 31-day month of nonstop use, so no script costs more than 100 EUR a month. The maximum is a constant because a CHECK can''t read payments.config.';


CREATE TABLE IF NOT EXISTS "scripts"."protected" (
    "id" "uuid" NOT NULL,
    "author" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "revision" integer DEFAULT 0 NOT NULL,
    "last_revision" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

COMMENT ON COLUMN "scripts"."protected"."revision" IS 'The live revision. 0 means none yet, and the script can''t be run.';

COMMENT ON COLUMN "scripts"."protected"."last_revision" IS 'Revision allocator. Counts pending and discarded revisions too.';


-- The file list of a revision, checked by versions_files_check (defined before the table
-- because the CHECK calls it): 1 to 50 unique paths of at most 200 characters, made of
-- letters, digits, _ . - and / between segments, with no "." or ".." segment. The webapp
-- applies the same rules (validFileName in #lib/scripts).
CREATE OR REPLACE FUNCTION "scripts"."valid_files"("files" "text"[]) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT cardinality(files) BETWEEN 1 AND 50
    AND cardinality(files) = (SELECT count(DISTINCT f) FROM unnest(files) f)
    AND NOT EXISTS (
      SELECT 1 FROM unnest(files) f
      WHERE f IS NULL
         OR char_length(f) > 200
         OR f !~ '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$'
         OR f ~ '(^|/)\.\.?(/|$)'
    );
$$;


CREATE TABLE IF NOT EXISTS "scripts"."versions" (
    "id" "uuid" NOT NULL,
    "revision" integer NOT NULL,
    "files" "text"[] NOT NULL,
    "status" "scripts"."version_status" DEFAULT 'pending'::"scripts"."version_status" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "published_at" timestamp with time zone,
    CONSTRAINT "versions_files_check" CHECK ("scripts"."valid_files"("files"))
);


CREATE TABLE IF NOT EXISTS "scripts"."bundles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "name" "text" NOT NULL,
    "scripts" "uuid"[] NOT NULL
);


-- Lets CI (GitHub Actions) publish revisions of one script without a user login. Only the
-- SHA-256 of the token is stored; the webapp shows the token once, when it is created.
CREATE TABLE IF NOT EXISTS "scripts"."deploy_tokens" (
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


ALTER TABLE ONLY "scripts"."scripts"
    ADD CONSTRAINT "scripts_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "scripts"."scripts"
    ADD CONSTRAINT "scripts_url_key" UNIQUE ("url");

ALTER TABLE ONLY "scripts"."slugs"
    ADD CONSTRAINT "slugs_pkey" PRIMARY KEY ("slug");

ALTER TABLE ONLY "scripts"."slugs"
    ADD CONSTRAINT "slugs_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;

CREATE INDEX "slugs_id_idx" ON "scripts"."slugs" ("id");

ALTER TABLE ONLY "scripts"."metadata"
    ADD CONSTRAINT "metadata_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "scripts"."protected"
    ADD CONSTRAINT "protected_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "scripts"."versions"
    ADD CONSTRAINT "versions_pkey" PRIMARY KEY ("id", "revision");

ALTER TABLE ONLY "scripts"."bundles"
    ADD CONSTRAINT "bundles_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "scripts"."metadata"
    ADD CONSTRAINT "metadata_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "scripts"."protected"
    ADD CONSTRAINT "protected_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;

-- A scripter's account can't be deleted while they still author scripts. Admin procedure: reassign the scripts
-- (service_role UPDATE scripts.protected SET author = ...) or delete them (service_role DELETE FROM scripts.scripts,
-- which cascades to metadata, protected, versions and stats; the storage files are removed through the Storage API),
-- then delete the account.
ALTER TABLE ONLY "scripts"."protected"
    ADD CONSTRAINT "protected_author_fkey" FOREIGN KEY ("author") REFERENCES "profiles"."profiles"("id") ON DELETE RESTRICT;

ALTER TABLE ONLY "scripts"."versions"
    ADD CONSTRAINT "versions_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "scripts"."bundles"
    ADD CONSTRAINT "bundles_author_fkey" FOREIGN KEY ("author") REFERENCES "profiles"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_token_hash_key" UNIQUE ("token_hash");

ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_script_id_fkey" FOREIGN KEY ("script_id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;

-- A token dies with the account that made it (a moderator's token on someone else's script, say)
ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

CREATE INDEX "deploy_tokens_script_id_idx" ON "scripts"."deploy_tokens" USING "btree" ("script_id");

-- A script has at most one pending revision
CREATE UNIQUE INDEX "versions_one_pending_idx" ON "scripts"."versions" USING "btree" ("id") WHERE ("status" = 'pending'::"scripts"."version_status");

CREATE INDEX "idx_scripts_protected_author" ON "scripts"."protected" USING "btree" ("author");

CREATE INDEX "idx_scripts_bundles_author" ON "scripts"."bundles" USING "btree" ("author");

-- Helper functions

CREATE OR REPLACE FUNCTION "scripts"."get_revision"("script_id" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT revision FROM scripts.protected WHERE id = script_id;
$$;


-- The uuid in text, or NULL if it isn't one. Lets policies cast a path segment without erroring.
CREATE OR REPLACE FUNCTION "scripts"."safe_uuid"("value" "text") RETURNS "uuid"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT CASE
    WHEN value ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN value::uuid
  END;
$$;


CREATE OR REPLACE FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM scripts.protected WHERE id = script_id AND author = user_id
  );
$$;


CREATE OR REPLACE FUNCTION "scripts"."is_premium"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM scripts.metadata WHERE id = script_id AND type = 'premium'::scripts.type
  );
$$;


CREATE OR REPLACE FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE((SELECT stage = target_stage FROM scripts.metadata WHERE id = script_id), false);
$$;


CREATE OR REPLACE FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE((SELECT stage <= target_stage FROM scripts.metadata WHERE id = script_id), false);
$$;


CREATE OR REPLACE FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE((SELECT stage >= target_stage FROM scripts.metadata WHERE id = script_id), false);
$$;


-- Access functions (moved from the profiles schema)

-- Premium scripts are open to the author, tester+ and moderator+, and to anyone
-- whose credits cover the minimum balance (payments.required_balance). A script without a live
-- revision can't be run by anyone. The actual charging happens in payments sessions.
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


CREATE OR REPLACE FUNCTION "scripts"."can_access"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
      SELECT scripts.can_access(auth.uid(), script_id);
$$;


CREATE OR REPLACE FUNCTION "scripts"."can_view"("viewer_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

-- Author usernames for the scripts in script_ids that the caller can view. Profiles are private,
-- so this is the only way other users see a name, and only a script author's name.
CREATE OR REPLACE FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) RETURNS TABLE ("script_id" "uuid", "username" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT p.id, u.username
  FROM scripts.protected p
  JOIN profiles.profiles u ON u.id = p.author
  WHERE p.id = ANY(get_authors.script_ids)
    AND scripts.can_view(profiles.uid(), p.id);
$$;


-- Trigger functions

-- The slug is the title alone ("auto-fighter") while it is free, and gets the
-- id suffix ("auto-fighter-1a2b3c4d") only on a collision with another script's
-- current or past slug. It follows title changes; scripts.slugs keeps the old
-- ones so their links redirect. Runs as definer because slugs is not readable
-- for scripts the caller can't view, and uniqueness has to see all of them.
CREATE OR REPLACE FUNCTION "scripts"."tr_scripts_set_url"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  base text;
  candidate text;
  len integer := 8;
BEGIN
  base := left(trim(both '-' from regexp_replace(lower(NEW.title), '[^a-z0-9]+', '-', 'g')), 80);
  base := trim(both '-' from base);
  IF base = '' THEN base := 'script'; END IF;

  -- Serialise scripts racing for the same slug.
  PERFORM pg_advisory_xact_lock(hashtext(base));

  -- "new" is the create-script route, so it never gets the clean form.
  candidate := base;
  IF base = 'new' OR EXISTS (
    SELECT 1 FROM "scripts"."slugs" WHERE "slug" = candidate AND "id" <> NEW.id
  ) THEN
    LOOP
      candidate := base || '-' || left(NEW.id::text, len);
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM "scripts"."slugs" WHERE "slug" = candidate AND "id" <> NEW.id
      );
      len := len + 4;
    END LOOP;
  END IF;

  NEW.url := candidate;
  RETURN NEW;
END;
$$;


-- Records the current slug once the scripts row exists (the FK needs it).
CREATE OR REPLACE FUNCTION "scripts"."tr_scripts_record_url"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  INSERT INTO "scripts"."slugs" ("slug", "id") VALUES (NEW.url, NEW.id) ON CONFLICT ("slug") DO NOTHING;
  RETURN NULL;
END;
$$;


-- Runs as definer so authors cannot insert (or forge) the protected/metadata/
-- versions rows themselves.
CREATE OR REPLACE FUNCTION "scripts"."tr_scripts_post_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  INSERT INTO scripts.protected (id, author) VALUES (NEW.id, auth.uid());
  INSERT INTO scripts.metadata (id) VALUES (NEW.id);
  INSERT INTO stats.limits (id) VALUES (NEW.id);
  INSERT INTO stats.limits_custom (id) VALUES (NEW.id);
  INSERT INTO stats.values (id) VALUES (NEW.id);
  INSERT INTO stats.values_custom (id) VALUES (NEW.id);
  INSERT INTO stats.website (id) VALUES (NEW.id);

  RETURN NEW;
END;
$$;


CREATE OR REPLACE FUNCTION "scripts"."tr_metadata_pre_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.stage < OLD.stage THEN
    RAISE EXCEPTION
      'Invalid stage transition: % → % is not allowed',
      OLD.stage, NEW.stage
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


-- The webapp creates a revision by inserting a versions row (id + files). The
-- revision number is assigned here, atomically, from the allocator. The row is
-- pending: protected.revision only changes when publish_version makes it live.
CREATE OR REPLACE FUNCTION "scripts"."tr_versions_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  UPDATE scripts.protected
  SET last_revision = last_revision + 1
  WHERE id = NEW.id
  RETURNING last_revision INTO NEW.revision;

  NEW.status := 'pending';
  NEW.published_at := NULL;

  RETURN NEW;
END;
$$;

-- Upload check for the scripts bucket: the object must be a listed file of the
-- script's pending revision (<id>/<9-digit revision>/<file>), and the user must
-- be its author or moderator+ (the caller, auth.uid(); no one can ask on behalf of
-- another user). A live or discarded revision can't receive files.
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

-- Read check for the scripts bucket: the author of the script the object belongs to
-- (the first path segment). Moderator+ is checked by the policy.
CREATE OR REPLACE FUNCTION "scripts"."is_object_author"("user_id" "uuid", "object_name" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT CASE
    WHEN split_part(object_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN scripts.is_author(user_id, split_part(object_name, '/', 1)::uuid)
    ELSE false
  END;
$$;

-- Makes a pending revision live once every listed file exists in the bucket.
-- Moderator+ may publish any script; banned users can't publish. service_role is the
-- deploy-token endpoint, which checks the token first (use_deploy_token).
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

-- Pending -> discarded. A service job (API, Storage API) deletes the files of
-- discarded revisions: they must not be deleted through SQL on storage.objects.
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

-- Checks a deploy token (by its SHA-256) for a script and records its use. The token
-- only works while whoever made it may still publish the script: its author or moderator+,
-- and not banned.
-- Called by the webapp's deploy endpoint with service_role, before it creates the revision.
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

-- Triggers

CREATE OR REPLACE TRIGGER "tr_scripts_pre_insert" BEFORE INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_set_url"();

CREATE OR REPLACE TRIGGER "tr_scripts_pre_update" BEFORE UPDATE OF "title" ON "scripts"."scripts" FOR EACH ROW WHEN (OLD."title" IS DISTINCT FROM NEW."title") EXECUTE FUNCTION "scripts"."tr_scripts_set_url"();

CREATE OR REPLACE TRIGGER "tr_scripts_record_url" AFTER INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_record_url"();

-- Not "UPDATE OF url": a rename only sets title, and column triggers ignore what BEFORE triggers change.
-- An AFTER trigger's WHEN sees the final row, so this catches the slug tr_scripts_pre_update picked.
CREATE OR REPLACE TRIGGER "tr_scripts_record_renamed_url" AFTER UPDATE ON "scripts"."scripts" FOR EACH ROW WHEN (OLD."url" IS DISTINCT FROM NEW."url") EXECUTE FUNCTION "scripts"."tr_scripts_record_url"();

CREATE OR REPLACE TRIGGER "tr_scripts_post_insert" AFTER INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_post_insert"();

CREATE OR REPLACE TRIGGER "tr_metadata_pre_update" BEFORE UPDATE ON "scripts"."metadata" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_metadata_pre_update"();

CREATE OR REPLACE TRIGGER "tr_versions_pre_insert" BEFORE INSERT ON "scripts"."versions" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_versions_pre_insert"();

-- Fires when a revision goes live, not on every insert, update and delete
CREATE OR REPLACE TRIGGER "wh-scripts.versions" AFTER UPDATE OF "status" ON "scripts"."versions" FOR EACH ROW WHEN (NEW."status" = 'live'::"scripts"."version_status") EXECUTE FUNCTION "public"."webhook"();

-- RLS

ALTER TABLE "scripts"."scripts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "scripts"."slugs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "scripts"."metadata" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "scripts"."protected" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "scripts"."versions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "scripts"."bundles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "scripts"."deploy_tokens" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for ALLOWED" ON "scripts"."scripts" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));

CREATE POLICY "SELECT for ALLOWED" ON "scripts"."slugs" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));

CREATE POLICY "SELECT for ALLOWED" ON "scripts"."metadata" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));

CREATE POLICY "SELECT for ALLOWED" ON "scripts"."protected" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));

-- File lists are internal: the API delivers the files. Regular users read the
-- live revision number from protected.revision.
CREATE POLICY "SELECT for AUTHOR" ON "scripts"."versions" FOR SELECT
    USING ("scripts"."is_author"("profiles"."uid"(), "id") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"));

CREATE POLICY "SELECT for EVERYONE" ON "scripts"."bundles" FOR SELECT USING (true);

CREATE POLICY "INSERT for SCRIPTER" ON "scripts"."scripts" FOR INSERT TO "authenticated"
    WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));

CREATE POLICY "INSERT for SCRIPTER" ON "scripts"."bundles" FOR INSERT TO "authenticated"
    WITH CHECK ("author" = "profiles"."uid"() AND "profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));

CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."scripts" FOR UPDATE TO "authenticated"
    USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")))
    WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));

CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."metadata" FOR UPDATE TO "authenticated"
    USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")))
    WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));

CREATE POLICY "INSERT for AUTHOR" ON "scripts"."versions" FOR INSERT TO "authenticated"
    WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));

CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."bundles" FOR UPDATE TO "authenticated"
    USING (("author" = "profiles"."uid"() OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")))
    WITH CHECK (("author" = "profiles"."uid"() OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));

-- Whoever may publish the script manages its deploy tokens
CREATE POLICY "SELECT for AUTHOR" ON "scripts"."deploy_tokens" FOR SELECT TO "authenticated"
    USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

CREATE POLICY "INSERT for AUTHOR" ON "scripts"."deploy_tokens" FOR INSERT TO "authenticated"
    WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

CREATE POLICY "DELETE for AUTHOR" ON "scripts"."deploy_tokens" FOR DELETE TO "authenticated"
    USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

-- Grants
-- Authors only touch the content columns. ids, urls, authors and revisions are
-- written by triggers or service_role. A revision's status changes only through
-- publish_version / discard_version. The only client DELETE grant is revoking a deploy token.

GRANT USAGE ON SCHEMA "scripts" TO "anon";
GRANT USAGE ON SCHEMA "scripts" TO "authenticated";
GRANT USAGE ON SCHEMA "scripts" TO "service_role";

REVOKE ALL ON TABLE "scripts"."scripts", "scripts"."metadata", "scripts"."protected", "scripts"."versions", "scripts"."bundles" FROM "anon", "authenticated";

GRANT SELECT ON TABLE "scripts"."slugs" TO "anon", "authenticated";
GRANT ALL ON TABLE "scripts"."slugs" TO "service_role";
GRANT SELECT ON TABLE "scripts"."scripts", "scripts"."metadata", "scripts"."protected", "scripts"."versions", "scripts"."bundles" TO "anon", "authenticated";
GRANT INSERT ("title", "description", "content") ON TABLE "scripts"."scripts" TO "authenticated";
GRANT UPDATE ("title", "description", "content", "published") ON TABLE "scripts"."scripts" TO "authenticated";
GRANT UPDATE ("type", "categories", "stage", "price") ON TABLE "scripts"."metadata" TO "authenticated";
GRANT INSERT ("id", "files") ON TABLE "scripts"."versions" TO "authenticated";
GRANT INSERT ("name", "scripts") ON TABLE "scripts"."bundles" TO "authenticated";
GRANT UPDATE ("name", "scripts") ON TABLE "scripts"."bundles" TO "authenticated";
GRANT ALL ON TABLE "scripts"."scripts", "scripts"."metadata", "scripts"."protected", "scripts"."versions", "scripts"."bundles" TO "service_role";

-- token_hash is write-only for clients; created_by comes from auth.uid()
REVOKE ALL ON TABLE "scripts"."deploy_tokens" FROM "anon", "authenticated";
GRANT SELECT ("id", "script_id", "name", "created_by", "created_at", "last_used_at") ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT INSERT ("script_id", "name", "token_hash") ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT DELETE ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT ALL ON TABLE "scripts"."deploy_tokens" TO "service_role";

-- Functions are executable by PUBLIC by default; lock down the privileged ones.
-- The policy helpers stay callable by anon because RLS policies call them.
REVOKE ALL ON FUNCTION "scripts"."tr_scripts_set_url"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."tr_scripts_record_url"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."tr_scripts_post_insert"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."tr_metadata_pre_update"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."tr_versions_pre_insert"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."is_object_author"("user_id" "uuid", "object_name" "text") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "scripts"."can_upload"("object_name" "text") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "scripts"."discard_version"("script_id" "uuid", "revision" integer) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "scripts"."use_deploy_token"("p_script" "uuid", "p_token_hash" "text") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "scripts"."use_deploy_token"("p_script" "uuid", "p_token_hash" "text") TO "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."discard_version"("script_id" "uuid", "revision" integer) TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."can_upload"("object_name" "text") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."is_object_author"("user_id" "uuid", "object_name" "text") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."get_revision"("script_id" "uuid") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."safe_uuid"("value" "text") TO "anon", "authenticated", "service_role";
-- Called by versions_files_check, so whoever inserts a revision needs it
REVOKE ALL ON FUNCTION "scripts"."valid_files"("files" "text"[]) FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "scripts"."valid_files"("files" "text"[]) TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."is_premium"("script_id" "uuid") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."can_access"("script_id" "uuid") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."can_view"("viewer_id" "uuid", "script_id" "uuid") TO "anon", "authenticated", "service_role";
REVOKE ALL ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) TO "anon", "authenticated", "service_role";
