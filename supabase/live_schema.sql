-- Live database snapshot, generated nightly by the sync task. Do not edit:
-- the source of truth is supabase/schemas/ and supabase/migrations/.




SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "info";


ALTER SCHEMA "info" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "payments";


ALTER SCHEMA "payments" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "profiles";


ALTER SCHEMA "profiles" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE SCHEMA IF NOT EXISTS "scripts";


ALTER SCHEMA "scripts" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "stats";


ALTER SCHEMA "stats" OWNER TO "postgres";


CREATE TYPE "info"."kind" AS ENUM (
    'privacy_policy',
    'user_tos',
    'scripter_tos'
);


ALTER TYPE "info"."kind" OWNER TO "supabase_admin";


CREATE TYPE "payments"."credit_kind" AS ENUM (
    'topup',
    'usage',
    'transfer',
    'refund',
    'adjustment'
);


ALTER TYPE "payments"."credit_kind" OWNER TO "supabase_admin";


CREATE TYPE "payments"."earning_kind" AS ENUM (
    'sale',
    'transfer',
    'withdrawal',
    'adjustment'
);


ALTER TYPE "payments"."earning_kind" OWNER TO "supabase_admin";


CREATE TYPE "payments"."payment_status" AS ENUM (
    'pending',
    'paid',
    'expired',
    'invalid'
);


ALTER TYPE "payments"."payment_status" OWNER TO "supabase_admin";


CREATE TYPE "payments"."provider" AS ENUM (
    'bitcart',
    'stripe',
    'molly'
);


ALTER TYPE "payments"."provider" OWNER TO "supabase_admin";


CREATE TYPE "payments"."session_end" AS ENUM (
    'stopped',
    'timeout',
    'insufficient_credits'
);


ALTER TYPE "payments"."session_end" OWNER TO "supabase_admin";


CREATE TYPE "profiles"."roles" AS ENUM (
    'user',
    'contributor',
    'tester',
    'scripter',
    'moderator',
    'administrator'
);


ALTER TYPE "profiles"."roles" OWNER TO "supabase_admin";


COMMENT ON TYPE "profiles"."roles" IS 'Profile roles, lowest to highest';



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


ALTER TYPE "scripts"."category" OWNER TO "supabase_admin";


COMMENT ON TYPE "scripts"."category" IS 'Script categories';



CREATE TYPE "scripts"."stage" AS ENUM (
    'prototype',
    'alpha',
    'beta',
    'stable',
    'archived'
);


ALTER TYPE "scripts"."stage" OWNER TO "supabase_admin";


COMMENT ON TYPE "scripts"."stage" IS 'Release lifecycle';



CREATE TYPE "scripts"."type" AS ENUM (
    'premium',
    'free'
);


ALTER TYPE "scripts"."type" OWNER TO "supabase_admin";


COMMENT ON TYPE "scripts"."type" IS 'Script type';



CREATE TYPE "scripts"."version_status" AS ENUM (
    'pending',
    'live',
    'discarded'
);


ALTER TYPE "scripts"."version_status" OWNER TO "supabase_admin";


COMMENT ON TYPE "scripts"."version_status" IS 'Revision lifecycle';



CREATE OR REPLACE FUNCTION "info"."tr_documents_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('info.documents.' || NEW.kind::text));

  SELECT COALESCE(max(version), 0) + 1 INTO NEW.version FROM info.documents WHERE kind = NEW.kind;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "info"."tr_documents_pre_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."adjust_credits"("p_admin" "uuid", "p_user" "uuid", "p_amount" bigint, "p_note" "text") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF p_admin IS NULL OR NOT profiles.is_role(p_admin, 'administrator') THEN
    RAISE EXCEPTION 'only administrators can adjust credits' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_amount IS NULL OR p_amount = 0 THEN
    RAISE EXCEPTION 'amount must not be zero';
  END IF;

  IF p_note IS NULL OR btrim(p_note) = '' THEN
    RAISE EXCEPTION 'a note is required';
  END IF;

  RETURN payments.post_credits(p_user, 'adjustment', p_amount, NULL, NULL, NULL, btrim(p_note), NULL, p_admin);
END;
$$;


ALTER FUNCTION "payments"."adjust_credits"("p_admin" "uuid", "p_user" "uuid", "p_amount" bigint, "p_note" "text") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."average_price"() RETURNS numeric
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT avg(m.price)
  FROM scripts.scripts s
  JOIN scripts.metadata m ON m.id = s.id
  JOIN scripts.protected p ON p.id = s.id
  WHERE s.published
    AND m.price > 0
    AND p.revision > 0
    AND m.stage IN ('beta'::scripts.stage, 'stable'::scripts.stage);
$$;


ALTER FUNCTION "payments"."average_price"() OWNER TO "supabase_admin";


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


ALTER FUNCTION "payments"."charge_session"("p_session" "uuid", "p_minutes" integer) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."end_session"("p_session" "uuid", "p_reason" "payments"."session_end") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_session payments.sessions;
  v_minutes integer;
  v_charged bigint;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session % not found', p_session;
  END IF;

  IF v_session.ended_at IS NOT NULL THEN
    RETURN 0;
  END IF;

  v_minutes := GREATEST(ceil(extract(epoch FROM (v_session.last_seen - v_session.charged_until)) / 60)::integer, 0);

  IF v_minutes = 0 AND v_session.charged_until = v_session.started_at THEN
    v_minutes := 1;
  END IF;

  v_charged := payments.charge_session(p_session, v_minutes);

  UPDATE payments.sessions
  SET ended_at = now(), end_reason = p_reason, charged_until = charged_until + make_interval(mins => v_minutes)
  WHERE id = p_session;

  RETURN v_charged;
END;
$$;


ALTER FUNCTION "payments"."end_session"("p_session" "uuid", "p_reason" "payments"."session_end") OWNER TO "supabase_admin";


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


ALTER FUNCTION "payments"."end_stale_sessions"() OWNER TO "supabase_admin";


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


ALTER FUNCTION "payments"."heartbeat_session"("p_session" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."post_credits"("p_user" "uuid", "p_kind" "payments"."credit_kind", "p_amount" bigint, "p_payment" "uuid" DEFAULT NULL::"uuid", "p_script" "uuid" DEFAULT NULL::"uuid", "p_minutes" integer DEFAULT NULL::integer, "p_note" "text" DEFAULT NULL::"text", "p_session" "uuid" DEFAULT NULL::"uuid", "p_actor" "uuid" DEFAULT NULL::"uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_balance bigint;
BEGIN
  UPDATE payments.accounts
  SET credits = credits + p_amount, updated_at = now()
  WHERE user_id = p_user
  RETURNING credits INTO v_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no payment account for user %', p_user;
  END IF;

  INSERT INTO payments.credits_ledger (user_id, kind, amount, balance_after, payment_id, script_id, session_id, minutes, note, granted_by)
  VALUES (p_user, p_kind, p_amount, v_balance, p_payment, p_script, p_session, p_minutes, p_note, p_actor);

  RETURN v_balance;
END;
$$;


ALTER FUNCTION "payments"."post_credits"("p_user" "uuid", "p_kind" "payments"."credit_kind", "p_amount" bigint, "p_payment" "uuid", "p_script" "uuid", "p_minutes" integer, "p_note" "text", "p_session" "uuid", "p_actor" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."post_earnings"("p_user" "uuid", "p_kind" "payments"."earning_kind", "p_amount" bigint, "p_script" "uuid" DEFAULT NULL::"uuid", "p_minutes" integer DEFAULT NULL::integer, "p_note" "text" DEFAULT NULL::"text", "p_session" "uuid" DEFAULT NULL::"uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_balance bigint;
BEGIN
  UPDATE payments.accounts
  SET earnings = earnings + p_amount, updated_at = now()
  WHERE user_id = p_user
  RETURNING earnings INTO v_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no payment account for user %', p_user;
  END IF;

  INSERT INTO payments.earnings_ledger (user_id, kind, amount, balance_after, script_id, session_id, minutes, note)
  VALUES (p_user, p_kind, p_amount, v_balance, p_script, p_session, p_minutes, p_note);

  RETURN v_balance;
END;
$$;


ALTER FUNCTION "payments"."post_earnings"("p_user" "uuid", "p_kind" "payments"."earning_kind", "p_amount" bigint, "p_script" "uuid", "p_minutes" integer, "p_note" "text", "p_session" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."required_balance"("p_price" bigint) RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT p_price * min_balance_minutes FROM payments.config;
$$;


ALTER FUNCTION "payments"."required_balance"("p_price" bigint) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."settle_payment"("p_payment" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_payment payments.payments;
BEGIN
  SELECT * INTO v_payment FROM payments.payments WHERE id = p_payment FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment % not found', p_payment;
  END IF;

  IF v_payment.status = 'paid' THEN
    RETURN false;
  END IF;

  UPDATE payments.payments SET status = 'paid', paid_at = now() WHERE id = p_payment;

  PERFORM payments.post_credits(v_payment.user_id, 'topup', v_payment.credits, p_payment);

  RETURN true;
END;
$$;


ALTER FUNCTION "payments"."settle_payment"("p_payment" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."start_session"("p_user" "uuid", "p_script" "uuid") RETURNS TABLE("session_id" "uuid", "revision" integer, "files" "text"[])
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


ALTER FUNCTION "payments"."start_session"("p_user" "uuid", "p_script" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."tr_accounts_pre_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  IF OLD.earnings > 0 THEN
    RAISE EXCEPTION 'account % still has earnings to pay out', OLD.user_id USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN OLD;
END;
$$;


ALTER FUNCTION "payments"."tr_accounts_pre_delete"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."tr_ledger_immutable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$;


ALTER FUNCTION "payments"."tr_ledger_immutable"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."tr_payments_limit_pending"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.user_id::text, 0));
  IF (SELECT count(*) FROM payments.payments WHERE user_id = NEW.user_id AND status = 'pending') >= 3 THEN
    RAISE EXCEPTION 'too many pending payments' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "payments"."tr_payments_limit_pending"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."tr_profiles_post_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  INSERT INTO payments.accounts (user_id) VALUES (NEW.id);
  RETURN NEW;
END;
$$;


ALTER FUNCTION "payments"."tr_profiles_post_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "payments"."transfer_earnings"("p_amount" bigint) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be positive';
  END IF;

  PERFORM payments.post_earnings(v_user, 'transfer', -p_amount, NULL, NULL, 'moved to credits');

  RETURN payments.post_credits(v_user, 'transfer', p_amount, NULL, NULL, NULL, 'moved from earnings');
END;
$$;


ALTER FUNCTION "payments"."transfer_earnings"("p_amount" bigint) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."clean_avatar"("url" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT CASE
    WHEN url ~ '^https://' AND char_length(url) <= 512 THEN url
    ELSE ''
  END;
$$;


ALTER FUNCTION "profiles"."clean_avatar"("url" "text") OWNER TO "supabase_admin";


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


ALTER FUNCTION "profiles"."clean_username"("name" "text", "id" "uuid") OWNER TO "supabase_admin";


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


ALTER FUNCTION "profiles"."get_provider_id"("user_id" "uuid", "provider" "text") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."get_roles_enum"() RETURNS "text"[]
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT enum_range(null::profiles.roles)::text[];
$$;


ALTER FUNCTION "profiles"."get_roles_enum"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."get_user_id"("provider" "text", "provider_id" "text") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT i.user_id
  FROM auth.identities i
  WHERE i.provider = get_user_id.provider AND i.provider_id = get_user_id.provider_id
  LIMIT 1;
$$;


ALTER FUNCTION "profiles"."get_user_id"("provider" "text", "provider_id" "text") OWNER TO "supabase_admin";


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


ALTER FUNCTION "profiles"."handle_new_user"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."is_role"("target_role" "profiles"."roles") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT profiles.is_role(auth.uid(), target_role);
$$;


ALTER FUNCTION "profiles"."is_role"("target_role" "profiles"."roles") OWNER TO "supabase_admin";


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


ALTER FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") OWNER TO "supabase_admin";


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


ALTER FUNCTION "profiles"."log_impersonation"("p_admin" "uuid", "p_user" "uuid") OWNER TO "supabase_admin";


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


ALTER FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") OWNER TO "supabase_admin";


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


ALTER FUNCTION "profiles"."refresh_avatar"() OWNER TO "supabase_admin";


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


ALTER FUNCTION "profiles"."require_discord"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."scrub_identity_email"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  NEW.identity_data := NEW.identity_data - 'email';
  RETURN NEW;
END;
$$;


ALTER FUNCTION "profiles"."scrub_identity_email"() OWNER TO "supabase_admin";


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


ALTER FUNCTION "profiles"."scrub_user_email"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."tr_impersonations_immutable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$;


ALTER FUNCTION "profiles"."tr_impersonations_immutable"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."uid"() RETURNS "uuid"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT auth.uid();
$$;


ALTER FUNCTION "profiles"."uid"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT encode(extensions.hmac(message::bytea, secret_key::bytea, 'sha256'), 'base64');
$$;


ALTER FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "public"."webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    secret text;
    base_url text;
    payload jsonb;
    request_id bigint;
BEGIN
    SELECT decrypted_secret INTO secret FROM vault.decrypted_secrets WHERE name = 'WEBHOOK_SECRET' LIMIT 1;
    SELECT decrypted_secret INTO base_url FROM vault.decrypted_secrets WHERE name = 'WEBHOOK_BASE_URL' LIMIT 1;

    IF secret IS NULL OR base_url IS NULL THEN
        RETURN NULL;
    END IF;

    payload := jsonb_build_object(
        'old_record', old,
        'record', new,
        'type', tg_op,
        'table', tg_table_name,
        'schema', tg_table_schema
    );

    SELECT net.http_post(
        format('%s/%s/%s', rtrim(base_url, '/'), tg_table_schema, tg_table_name),
        payload,
        '{}',
        jsonb_build_object(
            'Content-Type', 'application/json',
            'X-Supabase-Signature', public.generate_hmac(secret, payload::text)
        ),
        4000
    ) INTO request_id;

    INSERT INTO supabase_functions.hooks (hook_table_id, hook_name, request_id)
    VALUES (tg_relid, tg_name, request_id);

    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."webhook"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."can_access"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
      SELECT scripts.can_access(auth.uid(), script_id);
$$;


ALTER FUNCTION "scripts"."can_access"("script_id" "uuid") OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."can_upload"("object_name" "text") OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."can_view"("viewer_id" "uuid", "script_id" "uuid") OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."discard_version"("script_id" "uuid", "revision" integer) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) RETURNS TABLE("script_id" "uuid", "username" "text")
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


ALTER FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."get_revision"("script_id" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT revision FROM scripts.protected WHERE id = script_id;
$$;


ALTER FUNCTION "scripts"."get_revision"("script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM scripts.protected WHERE id = script_id AND author = user_id
  );
$$;


ALTER FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."is_object_author"("user_id" "uuid", "object_name" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $_$
  SELECT CASE
    WHEN split_part(object_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN scripts.is_author(user_id, split_part(object_name, '/', 1)::uuid)
    ELSE false
  END;
$_$;


ALTER FUNCTION "scripts"."is_object_author"("user_id" "uuid", "object_name" "text") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."is_premium"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM scripts.metadata WHERE id = script_id AND type = 'premium'::scripts.type
  );
$$;


ALTER FUNCTION "scripts"."is_premium"("script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE((SELECT stage = target_stage FROM scripts.metadata WHERE id = script_id), false);
$$;


ALTER FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE((SELECT stage <= target_stage FROM scripts.metadata WHERE id = script_id), false);
$$;


ALTER FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE((SELECT stage >= target_stage FROM scripts.metadata WHERE id = script_id), false);
$$;


ALTER FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."safe_uuid"("value" "text") RETURNS "uuid"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
  SELECT CASE
    WHEN value ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN value::uuid
  END;
$_$;


ALTER FUNCTION "scripts"."safe_uuid"("value" "text") OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."tr_metadata_pre_update"() OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."tr_scripts_post_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_scripts_record_url"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  INSERT INTO "scripts"."slugs" ("slug", "id") VALUES (NEW.url, NEW.id) ON CONFLICT ("slug") DO NOTHING;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "scripts"."tr_scripts_record_url"() OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."tr_scripts_set_url"() OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."tr_versions_pre_insert"() OWNER TO "supabase_admin";


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


ALTER FUNCTION "scripts"."use_deploy_token"("p_script" "uuid", "p_token_hash" "text") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."valid_files"("files" "text"[]) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
  SELECT cardinality(files) BETWEEN 1 AND 50
    AND cardinality(files) = (SELECT count(DISTINCT f) FROM unnest(files) f)
    AND NOT EXISTS (
      SELECT 1 FROM unnest(files) f
      WHERE f IS NULL
         OR char_length(f) > 200
         OR f !~ '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$'
         OR f ~ '(^|/)\.\.?(/|$)'
    );
$_$;


ALTER FUNCTION "scripts"."valid_files"("files" "text"[]) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stats"."can_manage"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT scripts.is_author(profiles.uid(), script_id) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles);
$$;


ALTER FUNCTION "stats"."can_manage"("script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stats"."get_level"("experience" bigint) RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT floor(experience / (13034431 / 99))::integer;
$$;


ALTER FUNCTION "stats"."get_level"("experience" bigint) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  UPDATE stats.values v
  SET experience = v.experience + add_experience,
      gold       = v.gold + add_gold,
      runtime    = v.runtime + add_runtime
  WHERE v.id = script_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No stats row for script %', script_id USING errcode = 'P0002';
  END IF;
END;
$$;


ALTER FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  INSERT INTO stats.stats AS s (id, experience, gold, runtime)
  VALUES (user_id, add_experience, add_gold, add_runtime)
  ON CONFLICT (id) DO UPDATE
  SET experience = s.experience + excluded.experience,
      gold       = s.gold + excluded.gold,
      runtime    = s.runtime + excluded.runtime;
$$;


ALTER FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stats"."online_count"() RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT count(DISTINCT s.user_id)
  FROM payments.sessions s
  WHERE s.ended_at IS NULL
    AND s.last_seen > now() - make_interval(mins => (SELECT c.session_timeout_minutes FROM payments.config c));
$$;


ALTER FUNCTION "stats"."online_count"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stats"."online_per_script"() RETURNS TABLE("script_id" "uuid", "users" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  WITH online AS MATERIALIZED (
    SELECT s.script_id, count(DISTINCT s.user_id) AS users
    FROM payments.sessions s
    WHERE s.ended_at IS NULL
      AND s.last_seen > now() - make_interval(mins => (SELECT c.session_timeout_minutes FROM payments.config c))
    GROUP BY s.script_id
  )
  SELECT o.script_id, o.users
  FROM online o
  WHERE scripts.can_view(profiles.uid(), o.script_id);
$$;


ALTER FUNCTION "stats"."online_per_script"() OWNER TO "supabase_admin";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "info"."documents" (
    "kind" "info"."kind" NOT NULL,
    "version" integer NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "info"."documents" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "payments"."accounts" (
    "user_id" "uuid" NOT NULL,
    "credits" bigint DEFAULT 0 NOT NULL,
    "earnings" bigint DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "accounts_credits_check" CHECK (("credits" >= 0)),
    CONSTRAINT "accounts_earnings_check" CHECK (("earnings" >= 0))
);


ALTER TABLE "payments"."accounts" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "payments"."config" (
    "id" boolean DEFAULT true NOT NULL,
    "platform_fee_bps" integer DEFAULT 2000 NOT NULL,
    "session_timeout_minutes" integer DEFAULT 5 NOT NULL,
    "min_balance_minutes" integer DEFAULT 1 NOT NULL,
    CONSTRAINT "config_check" CHECK ((("session_timeout_minutes" > 0) AND ("min_balance_minutes" > 0))),
    CONSTRAINT "config_fee_check" CHECK ((("platform_fee_bps" >= 0) AND ("platform_fee_bps" <= 10000))),
    CONSTRAINT "config_singleton" CHECK ("id")
);


ALTER TABLE "payments"."config" OWNER TO "supabase_admin";


COMMENT ON COLUMN "payments"."config"."platform_fee_bps" IS 'Platform cut of each usage charge in basis points (2000 = 20%).';



COMMENT ON COLUMN "payments"."config"."session_timeout_minutes" IS 'A session without a heartbeat for this long is ended with reason timeout.';



COMMENT ON COLUMN "payments"."config"."min_balance_minutes" IS 'A session needs a balance covering this many minutes at its price to start and to keep running (see payments.required_balance).';



CREATE TABLE IF NOT EXISTS "payments"."credits_ledger" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "payments"."credit_kind" NOT NULL,
    "amount" bigint NOT NULL,
    "balance_after" bigint NOT NULL,
    "payment_id" "uuid",
    "script_id" "uuid",
    "minutes" integer,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "session_id" "uuid",
    "granted_by" "uuid",
    CONSTRAINT "credits_ledger_amount_check" CHECK (("amount" <> 0))
);


ALTER TABLE "payments"."credits_ledger" OWNER TO "supabase_admin";


ALTER TABLE "payments"."credits_ledger" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "payments"."credits_ledger_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "payments"."earnings_ledger" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "payments"."earning_kind" NOT NULL,
    "amount" bigint NOT NULL,
    "balance_after" bigint NOT NULL,
    "script_id" "uuid",
    "minutes" integer,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "session_id" "uuid",
    CONSTRAINT "earnings_ledger_amount_check" CHECK (("amount" <> 0))
);


ALTER TABLE "payments"."earnings_ledger" OWNER TO "supabase_admin";


ALTER TABLE "payments"."earnings_ledger" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "payments"."earnings_ledger_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "payments"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "provider" "payments"."provider" NOT NULL,
    "provider_id" "text" NOT NULL,
    "status" "payments"."payment_status" DEFAULT 'pending'::"payments"."payment_status" NOT NULL,
    "credits" bigint NOT NULL,
    "currency" "text" DEFAULT 'EUR'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "paid_at" timestamp with time zone,
    "amount" bigint NOT NULL,
    "bonus" bigint DEFAULT 0 NOT NULL,
    CONSTRAINT "payments_amount_check" CHECK (("amount" > 0)),
    CONSTRAINT "payments_bonus_check" CHECK ((("bonus" >= 0) AND ("bonus" < "credits"))),
    CONSTRAINT "payments_credits_check" CHECK (("credits" > 0))
);


ALTER TABLE "payments"."payments" OWNER TO "supabase_admin";


COMMENT ON TABLE "payments"."payments" IS 'Provider invoices (Bitcart now, others later). provider_id is the provider''s own invoice id.';



COMMENT ON COLUMN "payments"."payments"."credits" IS 'Credits granted when the payment settles, bonus included.';



COMMENT ON COLUMN "payments"."payments"."amount" IS 'Amount paid, in the minor unit of currency (cents for EUR). Separate from credits so bonuses and other currencies stay possible.';



COMMENT ON COLUMN "payments"."payments"."bonus" IS 'Part of credits that is a top-up bonus rather than bought with amount.';



CREATE TABLE IF NOT EXISTS "payments"."sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "script_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "revision" integer NOT NULL,
    "price" bigint NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen" timestamp with time zone DEFAULT "now"() NOT NULL,
    "charged_until" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ended_at" timestamp with time zone,
    "unpaid" bigint DEFAULT 0 NOT NULL,
    "end_reason" "payments"."session_end",
    CONSTRAINT "sessions_end_check" CHECK ((("ended_at" IS NULL) = ("end_reason" IS NULL))),
    CONSTRAINT "sessions_price_check" CHECK (("price" >= 0)),
    CONSTRAINT "sessions_unpaid_check" CHECK (("unpaid" >= 0))
);


ALTER TABLE "payments"."sessions" OWNER TO "supabase_admin";


COMMENT ON TABLE "payments"."sessions" IS 'Usage sessions. price is fixed when the session starts (0 for free scripts and for the author and tester+). unpaid is the part of a charge the balance could not cover.';



CREATE TABLE IF NOT EXISTS "profiles"."impersonations" (
    "id" bigint NOT NULL,
    "admin_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "profiles"."impersonations" OWNER TO "supabase_admin";


ALTER TABLE "profiles"."impersonations" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "profiles"."impersonations_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "profiles"."profiles" (
    "id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "avatar" "text" DEFAULT ''::"text" NOT NULL,
    "role" "profiles"."roles" DEFAULT 'user'::"profiles"."roles" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "profiles_avatar_check" CHECK ((("avatar" = ''::"text") OR (("avatar" ~ '^https://'::"text") AND ("char_length"("avatar") <= 512)))),
    CONSTRAINT "profiles_username_check" CHECK ((("username" = "btrim"("username")) AND (("char_length"("username") >= 2) AND ("char_length"("username") <= 32)) AND ("username" !~ '[[:cntrl:]]'::"text")))
);


ALTER TABLE "profiles"."profiles" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."bundles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "name" "text" NOT NULL,
    "scripts" "uuid"[] NOT NULL
);


ALTER TABLE "scripts"."bundles" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."deploy_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "script_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "token_hash" "text" NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_used_at" timestamp with time zone,
    CONSTRAINT "deploy_tokens_name_check" CHECK ((("name" = "btrim"("name")) AND (("char_length"("name") >= 1) AND ("char_length"("name") <= 64)))),
    CONSTRAINT "deploy_tokens_token_hash_check" CHECK (("token_hash" ~ '^[0-9a-f]{64}$'::"text"))
);


ALTER TABLE "scripts"."deploy_tokens" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."metadata" (
    "id" "uuid" NOT NULL,
    "type" "scripts"."type" DEFAULT 'free'::"scripts"."type" NOT NULL,
    "categories" "scripts"."category"[] DEFAULT '{}'::"scripts"."category"[] NOT NULL,
    "stage" "scripts"."stage" DEFAULT 'prototype'::"scripts"."stage" NOT NULL,
    "price" bigint DEFAULT 0 NOT NULL,
    CONSTRAINT "metadata_price_check" CHECK ((("price" >= 0) AND (("type" = 'free'::"scripts"."type") = ("price" = 0)))),
    CONSTRAINT "metadata_price_max_check" CHECK (("price" <= 22))
);


ALTER TABLE "scripts"."metadata" OWNER TO "supabase_admin";


COMMENT ON COLUMN "scripts"."metadata"."price" IS 'Credits (1 credit = 0.01 cent EUR, 10,000 credits = 1 EUR) charged per minute of use. 0 for free scripts, 1 to 22 for premium ones: 22 a minute is about 98 EUR for a 31-day month of nonstop use, so no script costs more than 100 EUR a month. The maximum is a constant because a CHECK can''t read payments.config.';



CREATE TABLE IF NOT EXISTS "scripts"."protected" (
    "id" "uuid" NOT NULL,
    "author" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "revision" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_revision" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "scripts"."protected" OWNER TO "supabase_admin";


COMMENT ON COLUMN "scripts"."protected"."revision" IS 'The live revision. 0 means none yet, and the script can''t be run.';



COMMENT ON COLUMN "scripts"."protected"."last_revision" IS 'Revision allocator. Counts pending and discarded revisions too.';



CREATE TABLE IF NOT EXISTS "scripts"."scripts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "url" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "content" "text" NOT NULL,
    "published" boolean DEFAULT false NOT NULL
);


ALTER TABLE "scripts"."scripts" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."slugs" (
    "slug" "text" NOT NULL,
    "id" "uuid" NOT NULL
);


ALTER TABLE "scripts"."slugs" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."versions" (
    "id" "uuid" NOT NULL,
    "revision" integer NOT NULL,
    "files" "text"[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "published_at" timestamp with time zone,
    "status" "scripts"."version_status" DEFAULT 'pending'::"scripts"."version_status" NOT NULL,
    CONSTRAINT "versions_files_check" CHECK ("scripts"."valid_files"("files"))
);


ALTER TABLE "scripts"."versions" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."limits" (
    "id" "uuid" NOT NULL,
    "xp_min" integer DEFAULT 0 NOT NULL,
    "xp_max" integer DEFAULT 0 NOT NULL,
    "gp_min" bigint DEFAULT 0 NOT NULL,
    "gp_max" bigint DEFAULT 0 NOT NULL
);


ALTER TABLE "stats"."limits" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."limits_custom" (
    "id" "uuid" NOT NULL,
    "trackers" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "minima" bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    "maxima" bigint[] DEFAULT '{}'::bigint[] NOT NULL
);


ALTER TABLE "stats"."limits_custom" OWNER TO "supabase_admin";


COMMENT ON TABLE "stats"."limits_custom" IS 'Custom script stats';



CREATE TABLE IF NOT EXISTS "stats"."stats" (
    "id" "uuid" NOT NULL,
    "experience" bigint DEFAULT 0 NOT NULL,
    "gold" bigint DEFAULT 0 NOT NULL,
    "runtime" bigint DEFAULT 0 NOT NULL,
    "levels" integer GENERATED ALWAYS AS ("stats"."get_level"("experience")) STORED NOT NULL
);


ALTER TABLE "stats"."stats" OWNER TO "supabase_admin";


CREATE MATERIALIZED VIEW "stats"."totals" AS
 SELECT COALESCE("experience", (0)::bigint) AS "experience",
    COALESCE("gold", (0)::bigint) AS "gold",
    COALESCE("stats"."get_level"(COALESCE("experience", (0)::bigint)), 0) AS "levels",
    COALESCE("runtime", (0)::bigint) AS "runtime"
   FROM ( SELECT ("sum"("stats"."experience"))::bigint AS "experience",
            ("sum"("stats"."gold"))::bigint AS "gold",
            ("sum"("stats"."runtime"))::bigint AS "runtime"
           FROM "stats"."stats") "subquery"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "stats"."totals" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."values" (
    "id" "uuid" NOT NULL,
    "experience" bigint DEFAULT 0 NOT NULL,
    "gold" bigint DEFAULT 0 NOT NULL,
    "runtime" bigint DEFAULT 0 NOT NULL,
    "levels" integer GENERATED ALWAYS AS ("stats"."get_level"("experience")) STORED NOT NULL
);


ALTER TABLE "stats"."values" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."values_custom" (
    "id" "uuid" NOT NULL,
    "values" bigint[] DEFAULT '{}'::bigint[] NOT NULL
);


ALTER TABLE "stats"."values_custom" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."website" (
    "id" "uuid" NOT NULL,
    "downloads" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "total" bigint GENERATED ALWAYS AS (COALESCE("array_length"("downloads", 1), 0)) STORED
);


ALTER TABLE "stats"."website" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."website_monthly" (
    "id" "uuid" NOT NULL,
    "date" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL,
    "downloads" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "total" bigint GENERATED ALWAYS AS (COALESCE("array_length"("downloads", 1), 0)) STORED
);


ALTER TABLE "stats"."website_monthly" OWNER TO "supabase_admin";


ALTER TABLE ONLY "info"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("kind", "version");



ALTER TABLE ONLY "payments"."accounts"
    ADD CONSTRAINT "accounts_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "payments"."config"
    ADD CONSTRAINT "config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "payments"."credits_ledger"
    ADD CONSTRAINT "credits_ledger_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "payments"."earnings_ledger"
    ADD CONSTRAINT "earnings_ledger_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "payments"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "payments"."payments"
    ADD CONSTRAINT "payments_provider_id_key" UNIQUE ("provider", "provider_id");



ALTER TABLE ONLY "payments"."sessions"
    ADD CONSTRAINT "sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "profiles"."impersonations"
    ADD CONSTRAINT "impersonations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "scripts"."bundles"
    ADD CONSTRAINT "bundles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_token_hash_key" UNIQUE ("token_hash");



ALTER TABLE ONLY "scripts"."metadata"
    ADD CONSTRAINT "metadata_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "scripts"."protected"
    ADD CONSTRAINT "protected_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "scripts"."scripts"
    ADD CONSTRAINT "scripts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "scripts"."scripts"
    ADD CONSTRAINT "scripts_url_key" UNIQUE ("url");



ALTER TABLE ONLY "scripts"."slugs"
    ADD CONSTRAINT "slugs_pkey" PRIMARY KEY ("slug");



ALTER TABLE ONLY "scripts"."versions"
    ADD CONSTRAINT "versions_pkey" PRIMARY KEY ("id", "revision");



ALTER TABLE ONLY "stats"."limits_custom"
    ADD CONSTRAINT "limits_custom_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."limits"
    ADD CONSTRAINT "limits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."stats"
    ADD CONSTRAINT "stats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."values_custom"
    ADD CONSTRAINT "values_custom_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."values"
    ADD CONSTRAINT "values_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."website_monthly"
    ADD CONSTRAINT "website_monthly_pkey" PRIMARY KEY ("id", "date");



ALTER TABLE ONLY "stats"."website"
    ADD CONSTRAINT "website_pkey" PRIMARY KEY ("id");



CREATE INDEX "credits_ledger_adjustments_idx" ON "payments"."credits_ledger" USING "btree" ("id" DESC) WHERE ("kind" = 'adjustment'::"payments"."credit_kind");



CREATE INDEX "credits_ledger_user_id_idx" ON "payments"."credits_ledger" USING "btree" ("user_id", "id" DESC);



CREATE INDEX "earnings_ledger_script_id_idx" ON "payments"."earnings_ledger" USING "btree" ("script_id");



CREATE INDEX "earnings_ledger_user_id_idx" ON "payments"."earnings_ledger" USING "btree" ("user_id", "id" DESC);



CREATE INDEX "payments_user_id_idx" ON "payments"."payments" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "sessions_open_last_seen_idx" ON "payments"."sessions" USING "btree" ("last_seen") WHERE ("ended_at" IS NULL);



CREATE INDEX "sessions_user_id_idx" ON "payments"."sessions" USING "btree" ("user_id", "started_at" DESC);



CREATE INDEX "deploy_tokens_script_id_idx" ON "scripts"."deploy_tokens" USING "btree" ("script_id");



CREATE INDEX "idx_scripts_bundles_author" ON "scripts"."bundles" USING "btree" ("author");



CREATE INDEX "idx_scripts_protected_author" ON "scripts"."protected" USING "btree" ("author");



CREATE INDEX "slugs_id_idx" ON "scripts"."slugs" USING "btree" ("id");



CREATE UNIQUE INDEX "versions_one_pending_idx" ON "scripts"."versions" USING "btree" ("id") WHERE ("status" = 'pending'::"scripts"."version_status");



CREATE OR REPLACE TRIGGER "tr_documents_pre_insert" BEFORE INSERT ON "info"."documents" FOR EACH ROW EXECUTE FUNCTION "info"."tr_documents_pre_insert"();



CREATE OR REPLACE TRIGGER "tr_accounts_pre_delete" BEFORE DELETE ON "payments"."accounts" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_accounts_pre_delete"();



CREATE OR REPLACE TRIGGER "tr_ledger_immutable" BEFORE DELETE OR UPDATE ON "payments"."credits_ledger" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_ledger_immutable"();



CREATE OR REPLACE TRIGGER "tr_ledger_immutable" BEFORE DELETE OR UPDATE ON "payments"."earnings_ledger" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_ledger_immutable"();



CREATE OR REPLACE TRIGGER "tr_ledger_truncate" BEFORE TRUNCATE ON "payments"."credits_ledger" FOR EACH STATEMENT EXECUTE FUNCTION "payments"."tr_ledger_immutable"();



CREATE OR REPLACE TRIGGER "tr_ledger_truncate" BEFORE TRUNCATE ON "payments"."earnings_ledger" FOR EACH STATEMENT EXECUTE FUNCTION "payments"."tr_ledger_immutable"();



CREATE OR REPLACE TRIGGER "tr_payments_limit_pending" BEFORE INSERT ON "payments"."payments" FOR EACH ROW WHEN (("new"."status" = 'pending'::"payments"."payment_status")) EXECUTE FUNCTION "payments"."tr_payments_limit_pending"();



CREATE OR REPLACE TRIGGER "tr_impersonations_immutable" BEFORE DELETE OR UPDATE ON "profiles"."impersonations" FOR EACH ROW EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();



CREATE OR REPLACE TRIGGER "tr_impersonations_truncate" BEFORE TRUNCATE ON "profiles"."impersonations" FOR EACH STATEMENT EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();



CREATE OR REPLACE TRIGGER "tr_profiles_post_insert" AFTER INSERT ON "profiles"."profiles" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_profiles_post_insert"();



CREATE OR REPLACE TRIGGER "tr_metadata_pre_update" BEFORE UPDATE ON "scripts"."metadata" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_metadata_pre_update"();



CREATE OR REPLACE TRIGGER "tr_scripts_post_insert" AFTER INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_post_insert"();



CREATE OR REPLACE TRIGGER "tr_scripts_pre_insert" BEFORE INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_set_url"();



CREATE OR REPLACE TRIGGER "tr_scripts_pre_update" BEFORE UPDATE OF "title" ON "scripts"."scripts" FOR EACH ROW WHEN (("old"."title" IS DISTINCT FROM "new"."title")) EXECUTE FUNCTION "scripts"."tr_scripts_set_url"();



CREATE OR REPLACE TRIGGER "tr_scripts_record_renamed_url" AFTER UPDATE ON "scripts"."scripts" FOR EACH ROW WHEN (("old"."url" IS DISTINCT FROM "new"."url")) EXECUTE FUNCTION "scripts"."tr_scripts_record_url"();



CREATE OR REPLACE TRIGGER "tr_scripts_record_url" AFTER INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_record_url"();



CREATE OR REPLACE TRIGGER "tr_versions_pre_insert" BEFORE INSERT ON "scripts"."versions" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_versions_pre_insert"();



CREATE OR REPLACE TRIGGER "wh-scripts.versions" AFTER UPDATE OF "status" ON "scripts"."versions" FOR EACH ROW WHEN (("new"."status" = 'live'::"scripts"."version_status")) EXECUTE FUNCTION "public"."webhook"();



ALTER TABLE ONLY "payments"."accounts"
    ADD CONSTRAINT "accounts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "payments"."credits_ledger"
    ADD CONSTRAINT "credits_ledger_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "payments"."payments"("id");



ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."bundles"
    ADD CONSTRAINT "bundles_author_fkey" FOREIGN KEY ("author") REFERENCES "profiles"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."deploy_tokens"
    ADD CONSTRAINT "deploy_tokens_script_id_fkey" FOREIGN KEY ("script_id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."metadata"
    ADD CONSTRAINT "metadata_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."protected"
    ADD CONSTRAINT "protected_author_fkey" FOREIGN KEY ("author") REFERENCES "profiles"."profiles"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "scripts"."protected"
    ADD CONSTRAINT "protected_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."slugs"
    ADD CONSTRAINT "slugs_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."versions"
    ADD CONSTRAINT "versions_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."limits_custom"
    ADD CONSTRAINT "limits_custom_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."limits"
    ADD CONSTRAINT "limits_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."stats"
    ADD CONSTRAINT "stats_id_fkey" FOREIGN KEY ("id") REFERENCES "profiles"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."values_custom"
    ADD CONSTRAINT "values_custom_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."values"
    ADD CONSTRAINT "values_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."website"
    ADD CONSTRAINT "website_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."website_monthly"
    ADD CONSTRAINT "website_monthly_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



CREATE POLICY "INSERT for ADMINISTRATOR" ON "info"."documents" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."is_role"('administrator'::"profiles"."roles"));



CREATE POLICY "SELECT for EVERYONE" ON "info"."documents" FOR SELECT USING (true);



ALTER TABLE "info"."documents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "SELECT for OWNER" ON "payments"."accounts" FOR SELECT TO "authenticated" USING (("user_id" = "profiles"."uid"()));



CREATE POLICY "SELECT for OWNER" ON "payments"."credits_ledger" FOR SELECT TO "authenticated" USING (("user_id" = "profiles"."uid"()));



CREATE POLICY "SELECT for OWNER" ON "payments"."earnings_ledger" FOR SELECT TO "authenticated" USING (("user_id" = "profiles"."uid"()));



CREATE POLICY "SELECT for OWNER" ON "payments"."payments" FOR SELECT TO "authenticated" USING (("user_id" = "profiles"."uid"()));



CREATE POLICY "SELECT for OWNER" ON "payments"."sessions" FOR SELECT TO "authenticated" USING (("user_id" = "profiles"."uid"()));



ALTER TABLE "payments"."accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "payments"."config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "payments"."credits_ledger" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "payments"."earnings_ledger" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "payments"."payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "payments"."sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "SELECT for OWNER and MODERATOR" ON "profiles"."profiles" FOR SELECT TO "authenticated" USING ((("id" = ( SELECT "auth"."uid"() AS "uid")) OR "profiles"."min_role"(( SELECT "auth"."uid"() AS "uid"), 'moderator'::"profiles"."roles")));



CREATE POLICY "UPDATE for OWNER" ON "profiles"."profiles" FOR UPDATE TO "authenticated" USING (("id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "profiles"."impersonations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "profiles"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "DELETE for AUTHOR" ON "scripts"."deploy_tokens" FOR DELETE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));



CREATE POLICY "INSERT for AUTHOR" ON "scripts"."deploy_tokens" FOR INSERT TO "authenticated" WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));



CREATE POLICY "INSERT for AUTHOR" ON "scripts"."versions" FOR INSERT TO "authenticated" WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "INSERT for SCRIPTER" ON "scripts"."bundles" FOR INSERT TO "authenticated" WITH CHECK ((("author" = "profiles"."uid"()) AND "profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles")));



CREATE POLICY "INSERT for SCRIPTER" ON "scripts"."scripts" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));



CREATE POLICY "SELECT for ALLOWED" ON "scripts"."metadata" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));



CREATE POLICY "SELECT for ALLOWED" ON "scripts"."protected" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));



CREATE POLICY "SELECT for ALLOWED" ON "scripts"."scripts" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));



CREATE POLICY "SELECT for ALLOWED" ON "scripts"."slugs" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));



CREATE POLICY "SELECT for AUTHOR" ON "scripts"."deploy_tokens" FOR SELECT TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "script_id")));



CREATE POLICY "SELECT for AUTHOR" ON "scripts"."versions" FOR SELECT USING (("scripts"."is_author"("profiles"."uid"(), "id") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));



CREATE POLICY "SELECT for EVERYONE" ON "scripts"."bundles" FOR SELECT USING (true);



CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."bundles" FOR UPDATE TO "authenticated" USING ((("author" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))) WITH CHECK ((("author" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));



CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."metadata" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."scripts" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



ALTER TABLE "scripts"."bundles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."deploy_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."metadata" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."protected" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."scripts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."slugs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "SELECT for OWNER" ON "stats"."limits" FOR SELECT TO "authenticated" USING ("stats"."can_manage"("id"));



CREATE POLICY "SELECT for OWNER" ON "stats"."limits_custom" FOR SELECT TO "authenticated" USING ("stats"."can_manage"("id"));



CREATE POLICY "SELECT for OWNER" ON "stats"."values" FOR SELECT TO "authenticated" USING ("stats"."can_manage"("id"));



CREATE POLICY "SELECT for OWNER" ON "stats"."values_custom" FOR SELECT TO "authenticated" USING ("stats"."can_manage"("id"));



CREATE POLICY "SELECT for OWNER" ON "stats"."website" FOR SELECT TO "authenticated" USING (("scripts"."is_author"("profiles"."uid"(), "id") OR "profiles"."is_role"("profiles"."uid"(), 'administrator'::"profiles"."roles")));



CREATE POLICY "SELECT for OWNER" ON "stats"."website_monthly" FOR SELECT TO "authenticated" USING (("scripts"."is_author"("profiles"."uid"(), "id") OR "profiles"."is_role"("profiles"."uid"(), 'administrator'::"profiles"."roles")));



CREATE POLICY "SELECT for OWNER and MODERATOR" ON "stats"."stats" FOR SELECT TO "authenticated" USING ((("id" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));



CREATE POLICY "UPDATE for OWNER" ON "stats"."limits" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "UPDATE for OWNER" ON "stats"."limits_custom" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



ALTER TABLE "stats"."limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."limits_custom" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."stats" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."values" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."values_custom" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."website" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."website_monthly" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "info" TO "anon";
GRANT USAGE ON SCHEMA "info" TO "authenticated";
GRANT USAGE ON SCHEMA "info" TO "service_role";



GRANT USAGE ON SCHEMA "payments" TO "authenticated";
GRANT USAGE ON SCHEMA "payments" TO "service_role";



GRANT USAGE ON SCHEMA "profiles" TO "anon";
GRANT USAGE ON SCHEMA "profiles" TO "authenticated";
GRANT USAGE ON SCHEMA "profiles" TO "service_role";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT USAGE ON SCHEMA "scripts" TO "anon";
GRANT USAGE ON SCHEMA "scripts" TO "authenticated";
GRANT USAGE ON SCHEMA "scripts" TO "service_role";



GRANT USAGE ON SCHEMA "stats" TO "anon";
GRANT USAGE ON SCHEMA "stats" TO "authenticated";
GRANT USAGE ON SCHEMA "stats" TO "service_role";



GRANT ALL ON TYPE "payments"."session_end" TO "postgres";



GRANT ALL ON TYPE "scripts"."version_status" TO "postgres";



REVOKE ALL ON FUNCTION "info"."tr_documents_pre_insert"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "payments"."adjust_credits"("p_admin" "uuid", "p_user" "uuid", "p_amount" bigint, "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."adjust_credits"("p_admin" "uuid", "p_user" "uuid", "p_amount" bigint, "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "payments"."average_price"() FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."average_price"() TO "authenticated";
GRANT ALL ON FUNCTION "payments"."average_price"() TO "service_role";



REVOKE ALL ON FUNCTION "payments"."charge_session"("p_session" "uuid", "p_minutes" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."charge_session"("p_session" "uuid", "p_minutes" integer) TO "postgres";



REVOKE ALL ON FUNCTION "payments"."end_session"("p_session" "uuid", "p_reason" "payments"."session_end") FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."end_session"("p_session" "uuid", "p_reason" "payments"."session_end") TO "postgres";
GRANT ALL ON FUNCTION "payments"."end_session"("p_session" "uuid", "p_reason" "payments"."session_end") TO "service_role";



REVOKE ALL ON FUNCTION "payments"."end_stale_sessions"() FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."end_stale_sessions"() TO "postgres";
GRANT ALL ON FUNCTION "payments"."end_stale_sessions"() TO "service_role";



REVOKE ALL ON FUNCTION "payments"."heartbeat_session"("p_session" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."heartbeat_session"("p_session" "uuid") TO "postgres";
GRANT ALL ON FUNCTION "payments"."heartbeat_session"("p_session" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "payments"."post_credits"("p_user" "uuid", "p_kind" "payments"."credit_kind", "p_amount" bigint, "p_payment" "uuid", "p_script" "uuid", "p_minutes" integer, "p_note" "text", "p_session" "uuid", "p_actor" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."post_credits"("p_user" "uuid", "p_kind" "payments"."credit_kind", "p_amount" bigint, "p_payment" "uuid", "p_script" "uuid", "p_minutes" integer, "p_note" "text", "p_session" "uuid", "p_actor" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "payments"."post_earnings"("p_user" "uuid", "p_kind" "payments"."earning_kind", "p_amount" bigint, "p_script" "uuid", "p_minutes" integer, "p_note" "text", "p_session" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."post_earnings"("p_user" "uuid", "p_kind" "payments"."earning_kind", "p_amount" bigint, "p_script" "uuid", "p_minutes" integer, "p_note" "text", "p_session" "uuid") TO "postgres";
GRANT ALL ON FUNCTION "payments"."post_earnings"("p_user" "uuid", "p_kind" "payments"."earning_kind", "p_amount" bigint, "p_script" "uuid", "p_minutes" integer, "p_note" "text", "p_session" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "payments"."required_balance"("p_price" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."required_balance"("p_price" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "payments"."settle_payment"("p_payment" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."settle_payment"("p_payment" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "payments"."start_session"("p_user" "uuid", "p_script" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."start_session"("p_user" "uuid", "p_script" "uuid") TO "postgres";
GRANT ALL ON FUNCTION "payments"."start_session"("p_user" "uuid", "p_script" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "payments"."tr_accounts_pre_delete"() FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."tr_accounts_pre_delete"() TO "postgres";



REVOKE ALL ON FUNCTION "payments"."tr_ledger_immutable"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "payments"."tr_payments_limit_pending"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "payments"."tr_profiles_post_insert"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "payments"."transfer_earnings"("p_amount" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "payments"."transfer_earnings"("p_amount" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "payments"."transfer_earnings"("p_amount" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "profiles"."clean_avatar"("url" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "profiles"."clean_avatar"("url" "text") TO "postgres";
GRANT ALL ON FUNCTION "profiles"."clean_avatar"("url" "text") TO "service_role";



REVOKE ALL ON FUNCTION "profiles"."clean_username"("name" "text", "id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "profiles"."clean_username"("name" "text", "id" "uuid") TO "postgres";
GRANT ALL ON FUNCTION "profiles"."clean_username"("name" "text", "id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "profiles"."get_provider_id"("user_id" "uuid", "provider" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "profiles"."get_provider_id"("user_id" "uuid", "provider" "text") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."get_provider_id"("user_id" "uuid", "provider" "text") TO "service_role";



GRANT ALL ON FUNCTION "profiles"."get_roles_enum"() TO "anon";
GRANT ALL ON FUNCTION "profiles"."get_roles_enum"() TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."get_roles_enum"() TO "service_role";



REVOKE ALL ON FUNCTION "profiles"."get_user_id"("provider" "text", "provider_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "profiles"."get_user_id"("provider" "text", "provider_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "profiles"."handle_new_user"() FROM PUBLIC;



GRANT ALL ON FUNCTION "profiles"."is_role"("target_role" "profiles"."roles") TO "anon";
GRANT ALL ON FUNCTION "profiles"."is_role"("target_role" "profiles"."roles") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."is_role"("target_role" "profiles"."roles") TO "service_role";



GRANT ALL ON FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "anon";
GRANT ALL ON FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "service_role";



REVOKE ALL ON FUNCTION "profiles"."log_impersonation"("p_admin" "uuid", "p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "profiles"."log_impersonation"("p_admin" "uuid", "p_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "anon";
GRANT ALL ON FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "service_role";



REVOKE ALL ON FUNCTION "profiles"."refresh_avatar"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "profiles"."require_discord"() FROM PUBLIC;
GRANT ALL ON FUNCTION "profiles"."require_discord"() TO "postgres";



REVOKE ALL ON FUNCTION "profiles"."scrub_identity_email"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "profiles"."scrub_user_email"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "profiles"."tr_impersonations_immutable"() FROM PUBLIC;



GRANT ALL ON FUNCTION "profiles"."uid"() TO "anon";
GRANT ALL ON FUNCTION "profiles"."uid"() TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."uid"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."webhook"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."webhook"() TO "postgres";
GRANT ALL ON FUNCTION "public"."webhook"() TO "service_role";



GRANT ALL ON FUNCTION "scripts"."can_access"("script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "scripts"."can_access"("script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."can_access"("script_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "scripts"."can_upload"("object_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "scripts"."can_upload"("object_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."can_upload"("object_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."can_view"("viewer_id" "uuid", "script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "scripts"."can_view"("viewer_id" "uuid", "script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."can_view"("viewer_id" "uuid", "script_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "scripts"."discard_version"("script_id" "uuid", "revision" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "scripts"."discard_version"("script_id" "uuid", "revision" integer) TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."discard_version"("script_id" "uuid", "revision" integer) TO "postgres";
GRANT ALL ON FUNCTION "scripts"."discard_version"("script_id" "uuid", "revision" integer) TO "service_role";



REVOKE ALL ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "scripts"."get_revision"("script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "scripts"."get_revision"("script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."get_revision"("script_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "scripts"."is_object_author"("user_id" "uuid", "object_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "scripts"."is_object_author"("user_id" "uuid", "object_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."is_object_author"("user_id" "uuid", "object_name" "text") TO "postgres";
GRANT ALL ON FUNCTION "scripts"."is_object_author"("user_id" "uuid", "object_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."is_premium"("script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "scripts"."is_premium"("script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."is_premium"("script_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "anon";
GRANT ALL ON FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "anon";
GRANT ALL ON FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "anon";
GRANT ALL ON FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "service_role";



REVOKE ALL ON FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) TO "postgres";
GRANT ALL ON FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) TO "service_role";



GRANT ALL ON FUNCTION "scripts"."safe_uuid"("value" "text") TO "anon";
GRANT ALL ON FUNCTION "scripts"."safe_uuid"("value" "text") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."safe_uuid"("value" "text") TO "service_role";



REVOKE ALL ON FUNCTION "scripts"."tr_metadata_pre_update"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "scripts"."tr_scripts_post_insert"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "scripts"."tr_scripts_record_url"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "scripts"."tr_scripts_set_url"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "scripts"."tr_versions_pre_insert"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "scripts"."use_deploy_token"("p_script" "uuid", "p_token_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "scripts"."use_deploy_token"("p_script" "uuid", "p_token_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "scripts"."valid_files"("files" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "scripts"."valid_files"("files" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."valid_files"("files" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "stats"."can_manage"("script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "stats"."can_manage"("script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "stats"."can_manage"("script_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "stats"."get_level"("experience" bigint) TO "anon";
GRANT ALL ON FUNCTION "stats"."get_level"("experience" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "stats"."get_level"("experience" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) TO "service_role";



GRANT ALL ON FUNCTION "stats"."online_count"() TO "anon";
GRANT ALL ON FUNCTION "stats"."online_count"() TO "authenticated";
GRANT ALL ON FUNCTION "stats"."online_count"() TO "service_role";



GRANT ALL ON FUNCTION "stats"."online_per_script"() TO "anon";
GRANT ALL ON FUNCTION "stats"."online_per_script"() TO "authenticated";
GRANT ALL ON FUNCTION "stats"."online_per_script"() TO "service_role";



GRANT SELECT ON TABLE "info"."documents" TO "anon";
GRANT SELECT ON TABLE "info"."documents" TO "authenticated";
GRANT ALL ON TABLE "info"."documents" TO "service_role";



GRANT INSERT("kind") ON TABLE "info"."documents" TO "authenticated";



GRANT INSERT("content") ON TABLE "info"."documents" TO "authenticated";



GRANT SELECT ON TABLE "payments"."accounts" TO "authenticated";
GRANT SELECT ON TABLE "payments"."accounts" TO "service_role";



GRANT ALL ON TABLE "payments"."config" TO "service_role";



GRANT SELECT ON TABLE "payments"."credits_ledger" TO "authenticated";
GRANT SELECT ON TABLE "payments"."credits_ledger" TO "service_role";



GRANT SELECT ON TABLE "payments"."earnings_ledger" TO "authenticated";
GRANT SELECT ON TABLE "payments"."earnings_ledger" TO "service_role";



GRANT SELECT ON TABLE "payments"."payments" TO "authenticated";
GRANT ALL ON TABLE "payments"."payments" TO "service_role";



GRANT SELECT ON TABLE "payments"."sessions" TO "authenticated";
GRANT ALL ON TABLE "payments"."sessions" TO "postgres";
GRANT SELECT ON TABLE "payments"."sessions" TO "service_role";



GRANT SELECT ON TABLE "profiles"."impersonations" TO "service_role";



GRANT SELECT ON TABLE "profiles"."profiles" TO "authenticated";
GRANT ALL ON TABLE "profiles"."profiles" TO "service_role";



GRANT UPDATE("username") ON TABLE "profiles"."profiles" TO "authenticated";



GRANT SELECT ON TABLE "scripts"."bundles" TO "anon";
GRANT SELECT ON TABLE "scripts"."bundles" TO "authenticated";
GRANT ALL ON TABLE "scripts"."bundles" TO "service_role";



GRANT INSERT("name"),UPDATE("name") ON TABLE "scripts"."bundles" TO "authenticated";



GRANT INSERT("scripts"),UPDATE("scripts") ON TABLE "scripts"."bundles" TO "authenticated";



GRANT DELETE ON TABLE "scripts"."deploy_tokens" TO "authenticated";
GRANT ALL ON TABLE "scripts"."deploy_tokens" TO "service_role";



GRANT SELECT("id") ON TABLE "scripts"."deploy_tokens" TO "authenticated";



GRANT SELECT("script_id"),INSERT("script_id") ON TABLE "scripts"."deploy_tokens" TO "authenticated";



GRANT SELECT("name"),INSERT("name") ON TABLE "scripts"."deploy_tokens" TO "authenticated";



GRANT INSERT("token_hash") ON TABLE "scripts"."deploy_tokens" TO "authenticated";



GRANT SELECT("created_by") ON TABLE "scripts"."deploy_tokens" TO "authenticated";



GRANT SELECT("created_at") ON TABLE "scripts"."deploy_tokens" TO "authenticated";



GRANT SELECT("last_used_at") ON TABLE "scripts"."deploy_tokens" TO "authenticated";



GRANT SELECT ON TABLE "scripts"."metadata" TO "anon";
GRANT SELECT ON TABLE "scripts"."metadata" TO "authenticated";
GRANT ALL ON TABLE "scripts"."metadata" TO "service_role";



GRANT UPDATE("type") ON TABLE "scripts"."metadata" TO "authenticated";



GRANT UPDATE("categories") ON TABLE "scripts"."metadata" TO "authenticated";



GRANT UPDATE("stage") ON TABLE "scripts"."metadata" TO "authenticated";



GRANT UPDATE("price") ON TABLE "scripts"."metadata" TO "authenticated";



GRANT SELECT ON TABLE "scripts"."protected" TO "anon";
GRANT SELECT ON TABLE "scripts"."protected" TO "authenticated";
GRANT ALL ON TABLE "scripts"."protected" TO "service_role";



GRANT SELECT ON TABLE "scripts"."scripts" TO "anon";
GRANT SELECT ON TABLE "scripts"."scripts" TO "authenticated";
GRANT ALL ON TABLE "scripts"."scripts" TO "service_role";



GRANT INSERT("title"),UPDATE("title") ON TABLE "scripts"."scripts" TO "authenticated";



GRANT INSERT("description"),UPDATE("description") ON TABLE "scripts"."scripts" TO "authenticated";



GRANT INSERT("content"),UPDATE("content") ON TABLE "scripts"."scripts" TO "authenticated";



GRANT UPDATE("published") ON TABLE "scripts"."scripts" TO "authenticated";



GRANT SELECT ON TABLE "scripts"."slugs" TO "anon";
GRANT SELECT ON TABLE "scripts"."slugs" TO "authenticated";
GRANT ALL ON TABLE "scripts"."slugs" TO "service_role";



GRANT SELECT ON TABLE "scripts"."versions" TO "anon";
GRANT SELECT ON TABLE "scripts"."versions" TO "authenticated";
GRANT ALL ON TABLE "scripts"."versions" TO "service_role";



GRANT INSERT("id") ON TABLE "scripts"."versions" TO "authenticated";



GRANT INSERT("files") ON TABLE "scripts"."versions" TO "authenticated";



GRANT SELECT ON TABLE "stats"."limits" TO "authenticated";
GRANT ALL ON TABLE "stats"."limits" TO "service_role";



GRANT UPDATE("xp_min") ON TABLE "stats"."limits" TO "authenticated";



GRANT UPDATE("xp_max") ON TABLE "stats"."limits" TO "authenticated";



GRANT UPDATE("gp_min") ON TABLE "stats"."limits" TO "authenticated";



GRANT UPDATE("gp_max") ON TABLE "stats"."limits" TO "authenticated";



GRANT SELECT ON TABLE "stats"."limits_custom" TO "authenticated";
GRANT ALL ON TABLE "stats"."limits_custom" TO "service_role";



GRANT UPDATE("trackers") ON TABLE "stats"."limits_custom" TO "authenticated";



GRANT UPDATE("minima") ON TABLE "stats"."limits_custom" TO "authenticated";



GRANT UPDATE("maxima") ON TABLE "stats"."limits_custom" TO "authenticated";



GRANT SELECT ON TABLE "stats"."stats" TO "authenticated";
GRANT ALL ON TABLE "stats"."stats" TO "service_role";



GRANT ALL ON TABLE "stats"."totals" TO "service_role";



GRANT SELECT ON TABLE "stats"."values" TO "authenticated";
GRANT ALL ON TABLE "stats"."values" TO "service_role";



GRANT SELECT ON TABLE "stats"."values_custom" TO "authenticated";
GRANT ALL ON TABLE "stats"."values_custom" TO "service_role";



GRANT SELECT ON TABLE "stats"."website" TO "authenticated";
GRANT ALL ON TABLE "stats"."website" TO "service_role";



GRANT SELECT ON TABLE "stats"."website_monthly" TO "authenticated";
GRANT ALL ON TABLE "stats"."website_monthly" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";








-- RLS policies for Supabase's storage schema (extracted from a full storage dump).

CREATE POLICY "assets INSERT for service_role" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'assets'::"text"));

CREATE POLICY "assets SELECT for everyone" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'assets'::"text"));

CREATE POLICY "assets UPDATE for service_role" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'assets'::"text")) WITH CHECK (("bucket_id" = 'assets'::"text"));

ALTER TABLE "storage"."buckets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."buckets_analytics" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."buckets_vectors" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."iceberg_namespaces" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."iceberg_tables" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "imgs INSERT for author" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "imgs SELECT for everyone" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'imgs'::"text"));

CREATE POLICY "imgs UPDATE for author" ON "storage"."objects" FOR UPDATE USING ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")))) WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "launcher INSERT for service_role" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'launcher'::"text"));

CREATE POLICY "launcher SELECT for everyone" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'launcher'::"text"));

CREATE POLICY "launcher UPDATE for service_role" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'launcher'::"text")) WITH CHECK (("bucket_id" = 'launcher'::"text"));

ALTER TABLE "storage"."migrations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."objects" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."s3_multipart_uploads" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."s3_multipart_uploads_parts" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "scripts DELETE for supabase_admin" ON "storage"."objects" FOR DELETE USING ((("bucket_id" = 'scripts'::"text") AND (CURRENT_USER = 'supabase_admin'::"name")));

CREATE POLICY "scripts INSERT for author" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'scripts'::"text") AND "scripts"."can_upload"("name")));

CREATE POLICY "scripts SELECT for author" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'scripts'::"text") AND ("scripts"."is_object_author"("profiles"."uid"(), "name") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

ALTER TABLE "storage"."vector_indexes" ENABLE ROW LEVEL SECURITY;

