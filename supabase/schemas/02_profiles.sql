-- Schema: profiles (rewritten by hand for Volcren)
-- Apply order: public -> profiles -> scripts -> payments -> stats -> info (scripts.can_access reads payments.accounts at call time)
--
-- Profiles are keyed by auth.users.id. No emails, Stripe IDs or Discord IDs are
-- stored here: provider IDs are read from auth.identities (get_provider_id /
-- get_user_id), and OAuth emails are scrubbed by triggers on the auth tables.


CREATE SCHEMA IF NOT EXISTS "profiles";

ALTER SCHEMA "profiles" OWNER TO "postgres";

-- Order matters: min_role compares with >=
CREATE TYPE "profiles"."roles" AS ENUM (
    'user',
    'contributor',
    'tester',
    'scripter',
    'moderator',
    'administrator'
);


COMMENT ON TYPE "profiles"."roles" IS 'Profile roles, lowest to highest';

-- Table

CREATE TABLE IF NOT EXISTS "profiles"."profiles" (
    "id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "avatar" "text" DEFAULT ''::"text" NOT NULL,
    "role" "profiles"."roles" DEFAULT 'user'::"profiles"."roles" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "banned_at" timestamp with time zone
);


COMMENT ON COLUMN "profiles"."profiles"."banned_at" IS 'Set while the account is banned. Only profiles.set_banned writes it.';


ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");

-- Discord's own limits: 2-32 characters, no control characters, no padding
ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_username_check" CHECK (
        "username" = btrim("username")
        AND char_length("username") BETWEEN 2 AND 32
        AND "username" !~ '[[:cntrl:]]'
    );

ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_avatar_check" CHECK (
        "avatar" = '' OR ("avatar" ~ '^https://' AND char_length("avatar") <= 512)
    );

ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

-- Append-only record of administrators logging in as other users (the admin page's
-- impersonate action), written by log_impersonation. No FKs on purpose, like the
-- payments ledgers: the record outlives both accounts.
CREATE TABLE IF NOT EXISTS "profiles"."impersonations" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "admin_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "profiles"."impersonations"
    ADD CONSTRAINT "impersonations_pkey" PRIMARY KEY ("id");

-- Append-only record of every ban and unban (banned = false), written by set_banned.
-- No FKs, like impersonations.
CREATE TABLE IF NOT EXISTS "profiles"."bans" (
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

-- Functions

CREATE OR REPLACE FUNCTION "profiles"."uid"() RETURNS "uuid"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT auth.uid();
$$;


CREATE OR REPLACE FUNCTION "profiles"."get_roles_enum"() RETURNS "text"[]
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT enum_range(null::profiles.roles)::text[];
$$;


CREATE OR REPLACE FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT COALESCE(
    (SELECT p.role = target_role FROM profiles.profiles p WHERE p.id = user_id),
    false
  );
$$;


CREATE OR REPLACE FUNCTION "profiles"."is_role"("target_role" "profiles"."roles") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT profiles.is_role(auth.uid(), target_role);
$$;


CREATE OR REPLACE FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT COALESCE(
    (SELECT p.role >= target_role FROM profiles.profiles p WHERE p.id = user_id),
    false
  );
$$;


CREATE OR REPLACE FUNCTION "profiles"."is_banned"("user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT EXISTS (SELECT 1 FROM profiles.profiles p WHERE p.id = user_id AND p.banned_at IS NOT NULL);
$$;


-- Provider IDs (the Discord ID) are private: only the user themselves, moderator+ and service_role get them.
CREATE OR REPLACE FUNCTION "profiles"."get_provider_id"("user_id" "uuid", "provider" "text") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT i.provider_id
  FROM auth.identities i
  WHERE i.user_id = get_provider_id.user_id AND i.provider = get_provider_id.provider
    AND (
      auth.role() = 'service_role'
      OR get_provider_id.user_id = auth.uid()
      OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
    )
  LIMIT 1;
$$;

-- Used by the Discord bot (service_role only)
CREATE OR REPLACE FUNCTION "profiles"."get_user_id"("provider" "text", "provider_id" "text") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT i.user_id
  FROM auth.identities i
  WHERE i.provider = get_user_id.provider AND i.provider_id = get_user_id.provider_id
  LIMIT 1;
$$;


-- Sign-up pipeline
--
-- Caveats of the email scrubbing below:
--  * The first JWT issued during an OAuth sign-up, and possibly
--    auth.audit_log_entries.actor_username, can still contain the real email.
--  * Discord is the only login method, so every user gets the synthetic
--    <id>@volcren.com address.

-- Cleans a provider-supplied name so it satisfies profiles_username_check
CREATE OR REPLACE FUNCTION "profiles"."clean_username"("name" "text", "id" "uuid") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT CASE
    WHEN char_length(c) >= 2 THEN c
    ELSE 'user-' || left(id::text, 8)
  END
  FROM (
    SELECT btrim(left(btrim(regexp_replace(COALESCE(name, ''), '[[:cntrl:]]', '', 'g')), 32)) AS c
  ) t;
$$;

-- Stores '' for an avatar that would fail profiles_avatar_check
CREATE OR REPLACE FUNCTION "profiles"."clean_avatar"("url" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT CASE
    WHEN url ~ '^https://' AND char_length(url) <= 512 THEN url
    ELSE ''
  END;
$$;

CREATE OR REPLACE FUNCTION "profiles"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  meta jsonb := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
BEGIN
  INSERT INTO profiles.profiles (id, username, avatar)
  VALUES (
    NEW.id,
    profiles.clean_username(
      COALESCE(
        NULLIF(btrim(regexp_replace(COALESCE(meta -> 'custom_claims' ->> 'global_name', ''), '[[:cntrl:]]', '', 'g')), ''),
        NULLIF(btrim(regexp_replace(COALESCE(meta ->> 'full_name', ''), '[[:cntrl:]]', '', 'g')), ''),
        NULLIF(btrim(regexp_replace(split_part(COALESCE(meta ->> 'name', ''), '#', 1), '[[:cntrl:]]', '', 'g')), ''),
        NULLIF(btrim(regexp_replace(COALESCE(meta ->> 'user_name', ''), '[[:cntrl:]]', '', 'g')), '')
      ),
      NEW.id
    ),
    profiles.clean_avatar(COALESCE(
      NULLIF(meta ->> 'avatar_url', ''),
      NULLIF(meta ->> 'picture', ''),
      ''
    ))
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "profiles"."scrub_user_email"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  NEW.email := NEW.id::text || '@volcren.com';
  NEW.raw_user_meta_data := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb) - 'email';
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "profiles"."scrub_identity_email"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  NEW.identity_data := NEW.identity_data - 'email';
  RETURN NEW;
END;
$$;


CREATE OR REPLACE FUNCTION "profiles"."refresh_avatar"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  new_avatar text := profiles.clean_avatar(COALESCE(
    NULLIF(NEW.raw_user_meta_data ->> 'avatar_url', ''),
    NULLIF(NEW.raw_user_meta_data ->> 'picture', '')
  ));
BEGIN
  IF NULLIF(COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', NEW.raw_user_meta_data ->> 'picture'), '') IS NOT NULL THEN
    UPDATE profiles.profiles SET avatar = new_avatar
    WHERE id = NEW.id AND avatar IS DISTINCT FROM new_avatar;
  END IF;
  RETURN NULL;
END;
$$;


-- Second line of defence for Discord-only login: reject any other provider
-- if email or phone sign-up is ever switched on by mistake.
CREATE OR REPLACE FUNCTION "profiles"."require_discord"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  IF COALESCE(NEW.raw_app_meta_data ->> 'provider', '') <> 'discord' THEN
    RAISE EXCEPTION 'only Discord sign-in is allowed' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER "profiles_require_discord" BEFORE INSERT ON "auth"."users" FOR EACH ROW EXECUTE FUNCTION "profiles"."require_discord"();

-- Records an impersonation; the webapp calls it (service_role) before creating the
-- login, so an impersonation that can't be recorded doesn't happen. Administrators
-- can't impersonate each other.
CREATE OR REPLACE FUNCTION "profiles"."log_impersonation"("p_admin" "uuid", "p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF p_admin IS NULL OR NOT profiles.is_role(p_admin, 'administrator') THEN
    RAISE EXCEPTION 'only administrators can impersonate' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles.profiles WHERE id = p_user) THEN
    RAISE EXCEPTION 'user % not found', p_user USING ERRCODE = 'no_data_found';
  END IF;

  IF profiles.min_role(p_user, 'administrator') THEN
    RAISE EXCEPTION 'administrators cannot be impersonated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO profiles.impersonations (admin_id, user_id) VALUES (p_admin, p_user);
END;
$$;

-- Bans or unbans an account; the admin page calls it (service_role), then mirrors the state
-- to Auth (ban_duration) so a banned user can't sign in or refresh a session either. A ban
-- ends the user's running scripts, and banned users can't start scripts or publish revisions
-- (start_session, publish_version, use_deploy_token). Administrators can't be banned.
-- Returns false, recording nothing, when the account is already in that state.
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

CREATE OR REPLACE FUNCTION "profiles"."tr_impersonations_immutable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$;

CREATE OR REPLACE TRIGGER "tr_impersonations_immutable" BEFORE UPDATE OR DELETE ON "profiles"."impersonations" FOR EACH ROW EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();

CREATE OR REPLACE TRIGGER "tr_impersonations_truncate" BEFORE TRUNCATE ON "profiles"."impersonations" FOR EACH STATEMENT EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();

-- The ban record reuses the impersonations guard (its message names the table)
CREATE OR REPLACE TRIGGER "tr_bans_immutable" BEFORE UPDATE OR DELETE ON "profiles"."bans" FOR EACH ROW EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();

CREATE OR REPLACE TRIGGER "tr_bans_truncate" BEFORE TRUNCATE ON "profiles"."bans" FOR EACH STATEMENT EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();

-- Triggers on auth tables. Both BEFORE triggers run ahead of the AFTER one.
CREATE OR REPLACE TRIGGER "profiles_scrub_user_email" BEFORE INSERT OR UPDATE ON "auth"."users" FOR EACH ROW EXECUTE FUNCTION "profiles"."scrub_user_email"();

CREATE OR REPLACE TRIGGER "profiles_handle_new_user" AFTER INSERT ON "auth"."users" FOR EACH ROW EXECUTE FUNCTION "profiles"."handle_new_user"();

CREATE OR REPLACE TRIGGER "profiles_refresh_avatar" AFTER UPDATE OF "raw_user_meta_data" ON "auth"."users" FOR EACH ROW EXECUTE FUNCTION "profiles"."refresh_avatar"();

CREATE OR REPLACE TRIGGER "profiles_scrub_identity_email" BEFORE INSERT OR UPDATE ON "auth"."identities" FOR EACH ROW EXECUTE FUNCTION "profiles"."scrub_identity_email"();

-- RLS

ALTER TABLE "profiles"."profiles" ENABLE ROW LEVEL SECURITY;

-- Profiles are private: only the owner and moderator+ read them. The one public part,
-- the usernames of script authors, goes through scripts.get_authors.
CREATE POLICY "SELECT for OWNER and MODERATOR" ON "profiles"."profiles" FOR SELECT TO "authenticated"
    USING ((("id" = ( SELECT "auth"."uid"() AS "uid")) OR "profiles"."min_role"(( SELECT "auth"."uid"() AS "uid"), 'moderator'::"profiles"."roles")));

CREATE POLICY "UPDATE for OWNER" ON "profiles"."profiles" FOR UPDATE TO "authenticated"
    USING (("id" = ( SELECT "auth"."uid"() AS "uid")))
    WITH CHECK (("id" = ( SELECT "auth"."uid"() AS "uid")));

-- No policies: only service_role (the admin page) reads impersonations and bans
ALTER TABLE "profiles"."impersonations" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "profiles"."bans" ENABLE ROW LEVEL SECURITY;

-- Grants

GRANT USAGE ON SCHEMA "profiles" TO "anon";
GRANT USAGE ON SCHEMA "profiles" TO "authenticated";
GRANT USAGE ON SCHEMA "profiles" TO "service_role";

REVOKE ALL ON TABLE "profiles"."profiles" FROM "anon", "authenticated";
GRANT SELECT ON TABLE "profiles"."profiles" TO "authenticated";
-- avatar always mirrors the provider (refresh_avatar), so clients only edit the username
GRANT UPDATE ("username") ON TABLE "profiles"."profiles" TO "authenticated";
GRANT ALL ON TABLE "profiles"."profiles" TO "service_role";

-- Rows are only added by log_impersonation
REVOKE ALL ON TABLE "profiles"."impersonations" FROM "anon", "authenticated", "service_role";
GRANT SELECT ON TABLE "profiles"."impersonations" TO "service_role";

-- Rows are only added by set_banned
REVOKE ALL ON TABLE "profiles"."bans" FROM "anon", "authenticated", "service_role";
GRANT SELECT ON TABLE "profiles"."bans" TO "service_role";

-- Functions are executable by PUBLIC by default; lock down the privileged ones.
-- Revoking PUBLIC also drops anon, so the policy helpers are re-granted below.
REVOKE ALL ON FUNCTION "profiles"."handle_new_user"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."require_discord"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."scrub_user_email"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."scrub_identity_email"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."refresh_avatar"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."get_user_id"("provider" "text", "provider_id" "text") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."get_provider_id"("user_id" "uuid", "provider" "text") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "profiles"."clean_username"("name" "text", "id" "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."clean_avatar"("url" "text") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."log_impersonation"("p_admin" "uuid", "p_user" "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."tr_impersonations_immutable"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."set_banned"("p_admin" "uuid", "p_user" "uuid", "p_banned" boolean, "p_reason" "text") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."is_banned"("user_id" "uuid") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "profiles"."log_impersonation"("p_admin" "uuid", "p_user" "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."set_banned"("p_admin" "uuid", "p_user" "uuid", "p_banned" boolean, "p_reason" "text") TO "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."is_banned"("user_id" "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."clean_username"("name" "text", "id" "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."clean_avatar"("url" "text") TO "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."get_user_id"("provider" "text", "provider_id" "text") TO "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."get_provider_id"("user_id" "uuid", "provider" "text") TO "authenticated", "service_role";
-- Only policies TO authenticated call these (anyone who could execute them could learn a user's role from an ID).
REVOKE ALL ON FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."uid"() TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."get_roles_enum"() TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "profiles"."is_role"("target_role" "profiles"."roles") TO "anon", "authenticated", "service_role";
