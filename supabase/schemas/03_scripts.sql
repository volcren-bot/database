-- Schema: scripts (rewritten by hand for Volcren)
-- Apply order: public -> profiles -> scripts -> payments -> stats -> info (scripts.can_access reads payments.accounts at call time)
--
-- A script is a set of files (Luau and others) in the `scripts` storage bucket,
-- one folder per revision. Author names/avatars are not copied here: join profiles.profiles.
-- There are no script versions. Official or community is not stored: a script is community while
-- its author's role is below scripter (scripts.author_is_community). Community scripts are
-- visible only to their author, tester+ and people holding a grant from a share code.


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
    "sizes" bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    "entry" "text" NOT NULL,
    "status" "scripts"."version_status" DEFAULT 'pending'::"scripts"."version_status" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "published_at" timestamp with time zone,
    CONSTRAINT "versions_files_check" CHECK ("scripts"."valid_files"("files")),
    CONSTRAINT "versions_entry_check" CHECK ("entry" = ANY("files")),
    CONSTRAINT "versions_sizes_check" CHECK ((cardinality("sizes") = 0 OR cardinality("sizes") = cardinality("files")) AND 0 <= ALL("sizes"))
);

COMMENT ON COLUMN "scripts"."versions"."entry" IS 'The file the loader runs. One of files. Left out on insert, it is the only file of a single-file revision (tr_versions_pre_insert); a revision with several files has to name it.';

COMMENT ON COLUMN "scripts"."versions"."sizes" IS 'Byte size of each file in files, in the same order. Required for community authors, who are capped on storage; the real sizes are checked again when the revision goes live (publish_version).';

-- The AES-256 key that encrypts the files of one revision (see set_version_key). Only service_role reads it:
-- the API hands it to the loader when a session starts, so the files in the scripts bucket are useless without one.
CREATE TABLE IF NOT EXISTS "scripts"."version_keys" (
    "id" "uuid" NOT NULL,
    "revision" integer NOT NULL,
    "key" "bytea" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "version_keys_key_check" CHECK (octet_length("key") = 32)
);


CREATE TABLE IF NOT EXISTS "scripts"."bundles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "name" "text" NOT NULL,
    "scripts" "uuid"[] NOT NULL
);


-- The singleton row is inserted by a migration (declarative files cannot hold data).
CREATE TABLE IF NOT EXISTS "scripts"."config" (
    "id" boolean DEFAULT true NOT NULL,
    "max_community_scripts" integer DEFAULT 50 NOT NULL,
    "max_community_bytes" bigint DEFAULT 31457280 NOT NULL,
    "max_open_share_codes" integer DEFAULT 20 NOT NULL,
    "max_share_code_days" integer DEFAULT 30 NOT NULL,
    "redeem_max_failures" integer DEFAULT 10 NOT NULL,
    "redeem_window_minutes" integer DEFAULT 60 NOT NULL,
    CONSTRAINT "config_singleton" CHECK ("id"),
    CONSTRAINT "config_check" CHECK (
        "max_community_scripts" > 0 AND "max_community_bytes" > 0 AND "max_open_share_codes" > 0
        AND "max_share_code_days" > 0 AND "redeem_max_failures" > 0 AND "redeem_window_minutes" > 0
    )
);

COMMENT ON COLUMN "scripts"."config"."max_community_scripts" IS 'Scripts a community author (role below scripter) can have. Scripter+ has no limit.';

COMMENT ON COLUMN "scripts"."config"."max_community_bytes" IS 'Bytes of stored script files (every revision, pending, live or old) a community author can have: 30 MiB.';

COMMENT ON COLUMN "scripts"."config"."max_open_share_codes" IS 'Unredeemed, unexpired share codes a script can have at a time.';

COMMENT ON COLUMN "scripts"."config"."max_share_code_days" IS 'The furthest a share code expiry can be set.';

COMMENT ON COLUMN "scripts"."config"."redeem_max_failures" IS 'Failed share code redemptions an account gets per redeem_window_minutes before redeem_share_code stops answering.';

-- Hashes only, like deploy_tokens: the code is returned once by create_share_code and can't be read
-- back. A code is single-use; redeem_share_code marks it redeemed and adds the grant in one step.
CREATE TABLE IF NOT EXISTS "scripts"."share_codes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "script_id" "uuid" NOT NULL,
    "code_hash" "text" NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "redeemed_by" "uuid",
    "redeemed_at" timestamp with time zone,
    CONSTRAINT "share_codes_code_hash_check" CHECK ("code_hash" ~ '^[0-9a-f]{64}$'),
    CONSTRAINT "share_codes_expires_check" CHECK ("expires_at" > "created_at"),
    CONSTRAINT "share_codes_redeemed_check" CHECK (("redeemed_by" IS NULL) = ("redeemed_at" IS NULL))
);

-- Who may run a script that its rules would otherwise hide from them. A grant bypasses stage,
-- published and archived on official scripts and makes a premium script free for the holder.
CREATE TABLE IF NOT EXISTS "scripts"."grants" (
    "script_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "code_id" "uuid" NOT NULL,
    "granted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

-- Failed redemptions, counted by redeem_share_code (a raised error would roll the row back)
CREATE TABLE IF NOT EXISTS "scripts"."redeem_attempts" (
    "user_id" "uuid" NOT NULL,
    "attempted_at" timestamp with time zone DEFAULT "now"() NOT NULL
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

ALTER TABLE ONLY "scripts"."version_keys"
    ADD CONSTRAINT "version_keys_pkey" PRIMARY KEY ("id", "revision");

ALTER TABLE ONLY "scripts"."version_keys"
    ADD CONSTRAINT "version_keys_version_fkey" FOREIGN KEY ("id", "revision") REFERENCES "scripts"."versions"("id", "revision") ON UPDATE CASCADE ON DELETE CASCADE;

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

ALTER TABLE ONLY "scripts"."config"
    ADD CONSTRAINT "config_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "scripts"."share_codes"
    ADD CONSTRAINT "share_codes_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "scripts"."share_codes"
    ADD CONSTRAINT "share_codes_code_hash_key" UNIQUE ("code_hash");

ALTER TABLE ONLY "scripts"."share_codes"
    ADD CONSTRAINT "share_codes_script_id_fkey" FOREIGN KEY ("script_id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "scripts"."share_codes"
    ADD CONSTRAINT "share_codes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "scripts"."share_codes"
    ADD CONSTRAINT "share_codes_redeemed_by_fkey" FOREIGN KEY ("redeemed_by") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

CREATE INDEX "share_codes_script_id_idx" ON "scripts"."share_codes" USING "btree" ("script_id");

ALTER TABLE ONLY "scripts"."grants"
    ADD CONSTRAINT "grants_pkey" PRIMARY KEY ("script_id", "user_id");

ALTER TABLE ONLY "scripts"."grants"
    ADD CONSTRAINT "grants_script_id_fkey" FOREIGN KEY ("script_id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "scripts"."grants"
    ADD CONSTRAINT "grants_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "scripts"."grants"
    ADD CONSTRAINT "grants_code_id_fkey" FOREIGN KEY ("code_id") REFERENCES "scripts"."share_codes"("id") ON DELETE CASCADE;

CREATE INDEX "grants_user_id_idx" ON "scripts"."grants" USING "btree" ("user_id");

ALTER TABLE ONLY "scripts"."redeem_attempts"
    ADD CONSTRAINT "redeem_attempts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

CREATE INDEX "redeem_attempts_user_id_idx" ON "scripts"."redeem_attempts" USING "btree" ("user_id", "attempted_at");

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


-- Community scripts are the ones whose author's role is below scripter. The role decides, so a
-- promotion or demotion changes the tag of every script the author owns.
CREATE OR REPLACE FUNCTION "scripts"."author_is_community"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT COALESCE((
    SELECT a.role < 'scripter'::profiles.roles
    FROM scripts.protected p
    JOIN profiles.profiles a ON a.id = p.author
    WHERE p.id = script_id
  ), false);
$$;


CREATE OR REPLACE FUNCTION "scripts"."author_is_banned"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT COALESCE((
    SELECT a.banned_at IS NOT NULL
    FROM scripts.protected p
    JOIN profiles.profiles a ON a.id = p.author
    WHERE p.id = script_id
  ), false);
$$;


CREATE OR REPLACE FUNCTION "scripts"."has_grant"("user_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT EXISTS (SELECT 1 FROM scripts.grants g WHERE g.user_id = has_grant.user_id AND g.script_id = has_grant.script_id);
$$;


-- A community script whose author isn't banned: what tester+ may read the files of (the
-- scripts.versions and scripts bucket SELECT policies)
CREATE OR REPLACE FUNCTION "scripts"."is_reviewable"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT scripts.author_is_community(script_id) AND NOT scripts.author_is_banned(script_id);
$$;


-- Computed columns for listings: PostgREST selects and filters them like columns of scripts.scripts
-- (select=...,is_community,is_granted). They only describe scripts the caller can already see.
CREATE OR REPLACE FUNCTION "scripts"."is_community"("s" "scripts"."scripts") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT scripts.author_is_community(s.id);
$$;


CREATE OR REPLACE FUNCTION "scripts"."is_granted"("s" "scripts"."scripts") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT COALESCE(scripts.has_grant(auth.uid(), s.id), false);
$$;


-- True only for moderator+, who are the only ones that can see a banned author's scripts
CREATE OR REPLACE FUNCTION "scripts"."author_banned"("s" "scripts"."scripts") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT profiles.min_role(auth.uid(), 'moderator'::profiles.roles) AND scripts.author_is_banned(s.id);
$$;


-- Bytes the author's script files take: for every revision the sizes the objects really have in the
-- scripts bucket. With reserve_pending, a pending revision counts at least its declared sizes, so
-- files it has yet to upload are already reserved (creating a revision); publish_version asks for
-- what is really stored.
CREATE OR REPLACE FUNCTION "scripts"."storage_used"("author_id" "uuid", "reserve_pending" boolean DEFAULT true) RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT COALESCE(sum(
    CASE WHEN reserve_pending AND v.status = 'pending'::scripts.version_status THEN GREATEST(d.declared, r.stored) ELSE r.stored END
  ), 0)::bigint
  FROM scripts.protected p
  JOIN scripts.versions v ON v.id = p.id
  CROSS JOIN LATERAL (
    SELECT COALESCE(sum((o.metadata ->> 'size')::bigint), 0) AS stored
    FROM storage.objects o
    WHERE o.bucket_id = 'scripts'
      AND o.name LIKE v.id::text || '/' || lpad(v.revision::text, 9, '0') || '/%'
  ) r
  CROSS JOIN LATERAL (SELECT COALESCE(sum(z), 0) AS declared FROM unnest(v.sizes) z) d
  WHERE p.author = author_id;
$$;


-- What the caller has used of the community limits (the script page and /scripts/new show it)
CREATE OR REPLACE FUNCTION "scripts"."get_community_usage"() RETURNS TABLE ("script_count" integer, "used_bytes" bigint, "max_scripts" integer, "max_bytes" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT
    (SELECT count(*)::integer FROM scripts.protected p WHERE p.author = auth.uid()),
    scripts.storage_used(auth.uid()),
    c.max_community_scripts,
    c.max_community_bytes
  FROM scripts.config c
  WHERE auth.uid() IS NOT NULL;
$$;


-- Whether the caller may create a script: scripter+ or any other user, who in either case has to
-- have accepted the current terms, and who isn't banned unless scripter+ (as before). The
-- script limit is enforced by tr_scripts_post_insert, which can serialise concurrent inserts.
CREATE OR REPLACE FUNCTION "scripts"."can_create_script"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT auth.uid() IS NOT NULL
    AND profiles.has_accepted_terms(auth.uid())
    AND (profiles.min_role(auth.uid(), 'scripter'::profiles.roles) OR NOT profiles.is_banned(auth.uid()));
$$;


-- Access functions (moved from the profiles schema)

-- Premium scripts are open to the author, tester+ and moderator+, and to anyone
-- whose credits cover the minimum balance (payments.required_balance). A script without a live
-- revision can't be run by anyone. The actual charging happens in payments sessions.
-- A community script (author below scripter) is open to its author, tester+ and grantees whatever
-- its stage. A grant also opens an official script past stage, published and archived, and a
-- premium one for free. Nobody below moderator runs a banned author's scripts.
CREATE OR REPLACE FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
      WITH viewer AS (
              SELECT role FROM profiles.profiles WHERE id = accesser_id
      ),
      script AS (
              SELECT p.author, p.revision, m.type, m.stage, m.price, s.published,
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
                                                              OR COALESCE((SELECT a.credits FROM payments.accounts a WHERE a.user_id = accesser_id), 0) >= payments.required_balance(sc.price)
                                                      )
                                              )
                                      END
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


-- Who sees a script: moderator+ always, nobody else when its author is banned, then its author and
-- grantees. Community scripts are then visible to tester+ only; official ones follow their stage
-- and published state.
CREATE OR REPLACE FUNCTION "scripts"."can_view"("viewer_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
      SELECT COALESCE((
        SELECT
          CASE
            WHEN COALESCE(v.role >= 'moderator'::profiles.roles, false) THEN true
            WHEN a.banned_at IS NOT NULL THEN false
            WHEN p.author = viewer_id THEN true
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
DECLARE
  v_role profiles.roles;
BEGIN
  INSERT INTO scripts.protected (id, author) VALUES (NEW.id, auth.uid());
  INSERT INTO scripts.metadata (id) VALUES (NEW.id);
  INSERT INTO stats.limits (id) VALUES (NEW.id);
  INSERT INTO stats.limits_custom (id) VALUES (NEW.id);
  INSERT INTO stats.values (id) VALUES (NEW.id);
  INSERT INTO stats.values_custom (id) VALUES (NEW.id);
  INSERT INTO stats.website (id) VALUES (NEW.id);

  SELECT p.role INTO v_role FROM profiles.profiles p WHERE p.id = auth.uid();

  IF v_role < 'scripter'::profiles.roles THEN
    -- Concurrent inserts of one author queue here, so each counts the others' scripts
    PERFORM pg_advisory_xact_lock(hashtext('scripts.community.' || auth.uid()::text));

    IF (SELECT count(*) FROM scripts.protected p WHERE p.author = auth.uid()) > (SELECT c.max_community_scripts FROM scripts.config c) THEN
      RAISE EXCEPTION 'community script limit reached' USING ERRCODE = 'check_violation';
    END IF;

    UPDATE profiles.profiles p SET role = 'contributor'::profiles.roles WHERE p.id = auth.uid() AND p.role = 'user'::profiles.roles;
  END IF;

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

  IF (NEW.type <> 'free'::scripts.type OR NEW.price <> 0) AND scripts.author_is_community(NEW.id) THEN
    RAISE EXCEPTION 'community scripts cannot be premium' USING ERRCODE = 'check_violation';
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

  -- A community author declares every file's size, and the revision has to fit what is left of
  -- their storage. The declared sizes can lie: publish_version checks the real ones.
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
$$;

-- Upload check for the scripts bucket: the object must be a listed file of the
-- script's pending revision (<id>/<9-digit revision>/<file>), and the user must
-- be its author or moderator+ (the caller, auth.uid(); no one can ask on behalf of
-- another user) and have accepted the current terms. A live or discarded revision can't receive files.
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
      AND profiles.has_accepted_terms(auth.uid())
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
-- Moderator+ may publish any script; banned users and users who haven't accepted the current terms
-- can't publish. A community author's storage must fit the cap. service_role is the
-- deploy-token endpoint, which checks the token first (use_deploy_token).
CREATE OR REPLACE FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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

  UPDATE scripts.protected p SET revision = publish_version.revision, updated_at = now()
  WHERE p.id = script_id;
END;
$$;

-- Stores the key a pending revision's files were encrypted with, given as 64 hex digits. The encrypted file is
-- nonce (12 bytes) || AES-256-GCM ciphertext and tag, authenticated with "volcren:<script id>/<9-digit revision>/<file>",
-- so it is 28 bytes larger than the plain file and only opens under its own name. The key is set once, before the
-- revision goes live. Same callers as publish_version.
CREATE OR REPLACE FUNCTION "scripts"."set_version_key"("script_id" "uuid", "revision" integer, "key" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND (auth.uid() IS NULL OR profiles.is_banned(auth.uid()) OR NOT (
    scripts.is_author(auth.uid(), script_id) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  ) OR NOT profiles.has_accepted_terms(auth.uid())) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF key !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'the key must be 64 lowercase hex digits' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM scripts.versions v
    WHERE v.id = script_id AND v.revision = set_version_key.revision AND v.status = 'pending'::scripts.version_status
  ) THEN
    RAISE EXCEPTION 'no pending revision % of script %', revision, script_id;
  END IF;

  INSERT INTO scripts.version_keys (id, revision, key) VALUES (script_id, revision, decode(key, 'hex'));
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
-- not banned, and having accepted the current terms.
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
    AND profiles.has_accepted_terms(t.created_by)
  RETURNING t.id INTO v_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid deploy token' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN v_id;
END;
$$;

-- A contributor whose last script is gone is a plain user again
CREATE OR REPLACE FUNCTION "scripts"."tr_protected_post_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM scripts.protected p WHERE p.author = OLD.author) THEN
    UPDATE profiles.profiles p SET role = 'user'::profiles.roles
    WHERE p.id = OLD.author AND p.role = 'contributor'::profiles.roles;
  END IF;

  RETURN NULL;
END;
$$;

-- Share codes

-- Creates a single-use share code for a script and returns it. This is the only time the code
-- exists in clear: the table keeps its SHA-256, like deploy tokens. Whoever may publish the script
-- (its author, moderator+) can create codes, if not banned and on the current terms. A code
-- expires at p_expires_at, at most max_share_code_days from now, and a script holds at most
-- max_open_share_codes unredeemed, unexpired codes at a time.
CREATE OR REPLACE FUNCTION "scripts"."create_share_code"("p_script" "uuid", "p_expires_at" timestamp with time zone) RETURNS TABLE ("id" "uuid", "code" "text", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_cfg scripts.config;
  v_code text;
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR profiles.is_banned(auth.uid()) OR NOT (
    scripts.is_author(auth.uid(), p_script) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  ) OR NOT profiles.has_accepted_terms(auth.uid()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM scripts.scripts s WHERE s.id = p_script) THEN
    RAISE EXCEPTION 'script % not found', p_script USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_cfg FROM scripts.config;

  IF p_expires_at IS NULL OR p_expires_at <= now() OR p_expires_at > now() + make_interval(days => v_cfg.max_share_code_days) THEN
    RAISE EXCEPTION 'a share code expires within % days from now', v_cfg.max_share_code_days USING ERRCODE = 'check_violation';
  END IF;

  -- Concurrent creations for one script queue here, so each counts the others' codes
  PERFORM pg_advisory_xact_lock(hashtext('scripts.share_codes.' || p_script::text));

  IF (SELECT count(*) FROM scripts.share_codes c WHERE c.script_id = p_script AND c.redeemed_at IS NULL AND c.expires_at > now()) >= v_cfg.max_open_share_codes THEN
    RAISE EXCEPTION 'a script can have at most % open share codes', v_cfg.max_open_share_codes USING ERRCODE = 'check_violation';
  END IF;

  v_code := encode(extensions.gen_random_bytes(32), 'hex');

  INSERT INTO scripts.share_codes AS c (script_id, code_hash, expires_at)
  VALUES (p_script, encode(extensions.digest(v_code, 'sha256'), 'hex'), p_expires_at)
  RETURNING c.id INTO v_id;

  RETURN QUERY SELECT v_id, v_code, p_expires_at;
END;
$$;

-- Redeems a share code for the caller: checks it and, in one transaction, marks it redeemed and adds
-- the grant, so a code can never work twice, even for concurrent callers (the code's row is
-- locked until the first one commits). Answers with a status instead of raising, because a
-- raised error would roll back the failed attempt that the rate limit counts:
--   ok             the grant was added (script_id and url are set)
--   invalid        no such code, or its script's author is banned
--   expired, used  the code can't be redeemed any more
--   own            the caller wrote the script or made the code
--   already_access the caller can already see the script
--   rate_limited   redeem_max_failures failed attempts in the last redeem_window_minutes
-- invalid, expired and used count as failed attempts; the others leave the code unused.
CREATE OR REPLACE FUNCTION "scripts"."redeem_share_code"("p_code" "text") RETURNS TABLE ("status" "text", "script_id" "uuid", "url" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_user uuid := auth.uid();
  v_cfg scripts.config;
  v_code scripts.share_codes;
  v_author uuid;
  v_clean text := lower(btrim(COALESCE(p_code, '')));
  v_status text;
  v_url text;
  v_rows integer;
BEGIN
  IF v_user IS NULL OR profiles.is_banned(v_user) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_cfg FROM scripts.config;

  -- One redemption of an account at a time: the attempt count below can't be raced past
  PERFORM pg_advisory_xact_lock(hashtext('scripts.redeem.' || v_user::text));

  IF (SELECT count(*) FROM scripts.redeem_attempts a
      WHERE a.user_id = v_user AND a.attempted_at > now() - make_interval(mins => v_cfg.redeem_window_minutes)) >= v_cfg.redeem_max_failures THEN
    RETURN QUERY SELECT 'rate_limited'::text, NULL::uuid, NULL::text;
    RETURN;
  END IF;

  IF v_clean !~ '^[0-9a-f]{64}$' THEN
    v_status := 'invalid';
  ELSE
    SELECT * INTO v_code FROM scripts.share_codes c
    WHERE c.code_hash = encode(extensions.digest(v_clean, 'sha256'), 'hex')
    FOR UPDATE;

    IF NOT FOUND THEN
      v_status := 'invalid';
    ELSE
      SELECT p.author INTO v_author FROM scripts.protected p WHERE p.id = v_code.script_id;

      IF profiles.is_banned(v_author) THEN
        v_status := 'invalid';
      ELSIF v_code.redeemed_at IS NOT NULL THEN
        v_status := 'used';
      ELSIF v_code.expires_at <= now() THEN
        v_status := 'expired';
      ELSIF v_author = v_user OR v_code.created_by = v_user THEN
        v_status := 'own';
      ELSIF scripts.can_view(v_user, v_code.script_id) THEN
        v_status := 'already_access';
      ELSE
        INSERT INTO scripts.grants (script_id, user_id, code_id) VALUES (v_code.script_id, v_user, v_code.id)
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_rows = ROW_COUNT;

        IF v_rows = 0 THEN
          v_status := 'already_access';
        ELSE
          UPDATE scripts.share_codes c SET redeemed_by = v_user, redeemed_at = now() WHERE c.id = v_code.id;
          SELECT s.url INTO v_url FROM scripts.scripts s WHERE s.id = v_code.script_id;
          v_status := 'ok';
        END IF;
      END IF;
    END IF;
  END IF;

  IF v_status IN ('invalid', 'used', 'expired') THEN
    INSERT INTO scripts.redeem_attempts (user_id) VALUES (v_user);
  END IF;

  RETURN QUERY SELECT v_status, CASE WHEN v_status = 'ok' THEN v_code.script_id END, v_url;
END;
$$;

-- Who holds a grant on the script, by username (profiles are private, so the owner needs this).
-- For the script's author and moderator+.
CREATE OR REPLACE FUNCTION "scripts"."list_grantees"("p_script" "uuid") RETURNS TABLE ("user_id" "uuid", "username" "text", "granted_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT g.user_id, u.username, g.granted_at
  FROM scripts.grants g
  JOIN profiles.profiles u ON u.id = g.user_id
  WHERE g.script_id = p_script
    AND (scripts.is_author(auth.uid(), p_script) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles))
  ORDER BY g.granted_at;
$$;

-- Run by pg_cron (see the cron migration): drops unredeemed codes once expired, and the failed
-- redemptions that have left every rate limit window
CREATE OR REPLACE FUNCTION "scripts"."delete_expired_share_codes"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_count integer;
BEGIN
  DELETE FROM scripts.share_codes c WHERE c.redeemed_at IS NULL AND c.expires_at < now();
  GET DIAGNOSTICS v_count = ROW_COUNT;

  DELETE FROM scripts.redeem_attempts a
  WHERE a.attempted_at < now() - make_interval(mins => (SELECT c.redeem_window_minutes FROM scripts.config c));

  RETURN v_count;
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

CREATE OR REPLACE TRIGGER "tr_protected_post_delete" AFTER DELETE ON "scripts"."protected" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_protected_post_delete"();

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
ALTER TABLE "scripts"."config" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "scripts"."share_codes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "scripts"."grants" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "scripts"."redeem_attempts" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for ALLOWED" ON "scripts"."scripts" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));

CREATE POLICY "SELECT for ALLOWED" ON "scripts"."slugs" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));

CREATE POLICY "SELECT for ALLOWED" ON "scripts"."metadata" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));

CREATE POLICY "SELECT for ALLOWED" ON "scripts"."protected" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));

-- File lists are internal: the API delivers the files. Regular users read the
-- live revision number from protected.revision. Tester+ also review community scripts.
CREATE POLICY "SELECT for AUTHOR" ON "scripts"."versions" FOR SELECT TO "authenticated"
    USING ("scripts"."is_author"("profiles"."uid"(), "id") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")
           OR ("profiles"."min_role"("profiles"."uid"(), 'tester'::"profiles"."roles") AND "scripts"."is_reviewable"("id")));

CREATE POLICY "SELECT for EVERYONE" ON "scripts"."bundles" FOR SELECT USING (true);

-- Anyone on the current terms creates scripts; below scripter they are community scripts (limits
-- in tr_scripts_post_insert)
CREATE POLICY "INSERT for ALLOWED" ON "scripts"."scripts" FOR INSERT TO "authenticated"
    WITH CHECK ("scripts"."can_create_script"());

-- Only moderator+ deletes scripts (the cascade takes the rest of the script's rows). The files in the
-- scripts bucket go through the Storage API afterwards, never through SQL.
CREATE POLICY "DELETE for MODERATOR" ON "scripts"."scripts" FOR DELETE TO "authenticated"
    USING ("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"));

CREATE POLICY "SELECT for EVERYONE" ON "scripts"."config" FOR SELECT USING (true);

-- Whoever may publish the script manages its share codes (ids and dates only: the hash is never
-- readable). Only unredeemed codes can be revoked; a redeemed one stays as the record of its grant.
CREATE POLICY "SELECT for AUTHOR" ON "scripts"."share_codes" FOR SELECT TO "authenticated"
    USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

CREATE POLICY "DELETE for AUTHOR" ON "scripts"."share_codes" FOR DELETE TO "authenticated"
    USING ("redeemed_at" IS NULL AND ("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

-- A grant is seen and removed by its holder and by whoever manages the script
CREATE POLICY "SELECT for HOLDER and AUTHOR" ON "scripts"."grants" FOR SELECT TO "authenticated"
    USING (("user_id" = "profiles"."uid"() OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

CREATE POLICY "DELETE for HOLDER and AUTHOR" ON "scripts"."grants" FOR DELETE TO "authenticated"
    USING (("user_id" = "profiles"."uid"() OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));

-- No policies on redeem_attempts: only redeem_share_code and the cleanup job touch it

CREATE POLICY "INSERT for SCRIPTER" ON "scripts"."bundles" FOR INSERT TO "authenticated"
    WITH CHECK ("author" = "profiles"."uid"() AND "profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));

CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."scripts" FOR UPDATE TO "authenticated"
    USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")))
    WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));

CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."metadata" FOR UPDATE TO "authenticated"
    USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")))
    WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));

CREATE POLICY "INSERT for AUTHOR" ON "scripts"."versions" FOR INSERT TO "authenticated"
    WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")) AND "profiles"."has_accepted_terms"("profiles"."uid"()));

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
GRANT INSERT ("id", "files", "sizes", "entry") ON TABLE "scripts"."versions" TO "authenticated";
GRANT DELETE ON TABLE "scripts"."scripts" TO "authenticated";
GRANT INSERT ("name", "scripts") ON TABLE "scripts"."bundles" TO "authenticated";
GRANT UPDATE ("name", "scripts") ON TABLE "scripts"."bundles" TO "authenticated";
GRANT ALL ON TABLE "scripts"."scripts", "scripts"."metadata", "scripts"."protected", "scripts"."versions", "scripts"."bundles" TO "service_role";

-- token_hash is write-only for clients; created_by comes from auth.uid()
REVOKE ALL ON TABLE "scripts"."deploy_tokens" FROM "anon", "authenticated";
GRANT SELECT ("id", "script_id", "name", "created_by", "created_at", "last_used_at") ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT INSERT ("script_id", "name", "token_hash") ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT DELETE ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT ALL ON TABLE "scripts"."deploy_tokens" TO "service_role";

-- Share codes: ids and dates only; the hash is write-only through create_share_code
REVOKE ALL ON TABLE "scripts"."config", "scripts"."share_codes", "scripts"."grants", "scripts"."redeem_attempts" FROM "anon", "authenticated";
GRANT SELECT ON TABLE "scripts"."config" TO "anon", "authenticated";
GRANT SELECT ("id", "script_id", "created_by", "created_at", "expires_at", "redeemed_at") ON TABLE "scripts"."share_codes" TO "authenticated";
GRANT DELETE ON TABLE "scripts"."share_codes" TO "authenticated";
GRANT SELECT ("script_id", "user_id", "granted_at") ON TABLE "scripts"."grants" TO "authenticated";
GRANT DELETE ON TABLE "scripts"."grants" TO "authenticated";
GRANT ALL ON TABLE "scripts"."config", "scripts"."share_codes", "scripts"."grants", "scripts"."redeem_attempts" TO "service_role";

-- Encryption keys: no client can read or write them directly
ALTER TABLE "scripts"."version_keys" ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE "scripts"."version_keys" FROM "anon", "authenticated";
GRANT ALL ON TABLE "scripts"."version_keys" TO "service_role";
REVOKE ALL ON FUNCTION "scripts"."set_version_key"("script_id" "uuid", "revision" integer, "key" "text") FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "scripts"."set_version_key"("script_id" "uuid", "revision" integer, "key" "text") TO "authenticated", "service_role";

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
REVOKE ALL ON FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."can_access"("script_id" "uuid") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."can_view"("viewer_id" "uuid", "script_id" "uuid") TO "anon", "authenticated", "service_role";
REVOKE ALL ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) TO "anon", "authenticated", "service_role";

REVOKE ALL ON FUNCTION "scripts"."tr_protected_post_delete"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."delete_expired_share_codes"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."create_share_code"("p_script" "uuid", "p_expires_at" timestamp with time zone) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "scripts"."redeem_share_code"("p_code" "text") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "scripts"."list_grantees"("p_script" "uuid") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "scripts"."get_community_usage"() FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "scripts"."can_create_script"() FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "scripts"."storage_used"("author_id" "uuid", "reserve_pending" boolean) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."has_grant"("user_id" "uuid", "script_id" "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."author_is_banned"("script_id" "uuid") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "scripts"."create_share_code"("p_script" "uuid", "p_expires_at" timestamp with time zone) TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."redeem_share_code"("p_code" "text") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."list_grantees"("p_script" "uuid") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."get_community_usage"() TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."can_create_script"() TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."storage_used"("author_id" "uuid", "reserve_pending" boolean) TO "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."has_grant"("user_id" "uuid", "script_id" "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."author_is_banned"("script_id" "uuid") TO "service_role";
-- Called by tr_metadata_pre_update (as the caller), is_community and the policies
GRANT EXECUTE ON FUNCTION "scripts"."author_is_community"("script_id" "uuid") TO "anon", "authenticated", "service_role";
REVOKE ALL ON FUNCTION "scripts"."is_reviewable"("script_id" "uuid") FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "scripts"."is_reviewable"("script_id" "uuid") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."is_community"("s" "scripts"."scripts") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."is_granted"("s" "scripts"."scripts") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "scripts"."author_banned"("s" "scripts"."scripts") TO "anon", "authenticated", "service_role";
