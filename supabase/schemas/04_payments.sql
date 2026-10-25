-- Schema: payments (new for Volcren; replaces the Stripe schema)
-- Apply order: public -> profiles -> scripts -> payments -> stats -> info (scripts.can_access reads payments.accounts at call time)
--
-- Two append-only ledgers per user, both in credits (1 credit = 0.01 cent EUR, so 1 EUR = 10,000 credits):
--   credits_ledger   spendable balance, topped up through payments and spent per minute of script use (sessions)
--   earnings_ledger  what scripters earned from usage; can be moved into credits (transfer_earnings)
--                    and, later, withdrawn
-- payments.accounts caches both balances. Only the functions below write to it
-- and to the ledgers, and every ledger row stores the balance it resulted in.
-- Ledger and payment rows deliberately have no FK to profiles/scripts: they are
-- financial history and must survive account or script deletion.


CREATE SCHEMA IF NOT EXISTS "payments";

ALTER SCHEMA "payments" OWNER TO "postgres";

-- Types

CREATE TYPE "payments"."provider" AS ENUM ('bitcart', 'stripe', 'molly');


CREATE TYPE "payments"."payment_status" AS ENUM ('pending', 'paid', 'expired', 'invalid');


CREATE TYPE "payments"."credit_kind" AS ENUM ('topup', 'usage', 'transfer', 'refund', 'adjustment');


CREATE TYPE "payments"."earning_kind" AS ENUM ('sale', 'transfer', 'withdrawal', 'adjustment');


CREATE TYPE "payments"."session_end" AS ENUM ('stopped', 'timeout', 'insufficient_credits');

-- Tables

-- The singleton row is inserted by a migration (declarative files cannot hold data).
CREATE TABLE IF NOT EXISTS "payments"."config" (
    "id" boolean DEFAULT true NOT NULL,
    "platform_fee_bps" integer DEFAULT 2000 NOT NULL,
    "session_timeout_minutes" integer DEFAULT 5 NOT NULL,
    "min_balance_minutes" integer DEFAULT 1 NOT NULL,
    CONSTRAINT "config_singleton" CHECK ("id"),
    CONSTRAINT "config_fee_check" CHECK ("platform_fee_bps" BETWEEN 0 AND 10000),
    CONSTRAINT "config_check" CHECK ("session_timeout_minutes" > 0 AND "min_balance_minutes" > 0)
);


COMMENT ON COLUMN "payments"."config"."platform_fee_bps" IS 'Platform cut of each usage charge in basis points (2000 = 20%).';

COMMENT ON COLUMN "payments"."config"."session_timeout_minutes" IS 'A session without a heartbeat for this long is ended with reason timeout.';

COMMENT ON COLUMN "payments"."config"."min_balance_minutes" IS 'A session needs a balance covering this many minutes at its price to start and to keep running (see payments.required_balance).';

CREATE TABLE IF NOT EXISTS "payments"."accounts" (
    "user_id" "uuid" NOT NULL,
    "credits" bigint DEFAULT 0 NOT NULL,
    "earnings" bigint DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "accounts_credits_check" CHECK ("credits" >= 0),
    CONSTRAINT "accounts_earnings_check" CHECK ("earnings" >= 0)
);


CREATE TABLE IF NOT EXISTS "payments"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "provider" "payments"."provider" NOT NULL,
    "provider_id" "text" NOT NULL,
    "status" "payments"."payment_status" DEFAULT 'pending'::"payments"."payment_status" NOT NULL,
    "credits" bigint NOT NULL,
    "amount" bigint NOT NULL,
    "currency" "text" DEFAULT 'EUR'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "paid_at" timestamp with time zone,
    CONSTRAINT "payments_credits_check" CHECK ("credits" > 0),
    CONSTRAINT "payments_amount_check" CHECK ("amount" > 0)
);

COMMENT ON COLUMN "payments"."payments"."credits" IS 'Credits granted when the payment settles.';

COMMENT ON COLUMN "payments"."payments"."amount" IS 'Amount paid, in the minor unit of currency (cents for EUR). Separate from credits so bonuses and other currencies stay possible.';


COMMENT ON TABLE "payments"."payments" IS 'Provider invoices (Bitcart now, others later). provider_id is the provider''s own invoice id.';

CREATE TABLE IF NOT EXISTS "payments"."credits_ledger" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "payments"."credit_kind" NOT NULL,
    "amount" bigint NOT NULL,
    "balance_after" bigint NOT NULL,
    "payment_id" "uuid",
    "script_id" "uuid",
    "session_id" "uuid",
    "minutes" integer,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "credits_ledger_amount_check" CHECK ("amount" <> 0)
);


CREATE TABLE IF NOT EXISTS "payments"."earnings_ledger" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "payments"."earning_kind" NOT NULL,
    "amount" bigint NOT NULL,
    "balance_after" bigint NOT NULL,
    "script_id" "uuid",
    "session_id" "uuid",
    "minutes" integer,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "earnings_ledger_amount_check" CHECK ("amount" <> 0)
);


-- One row per run of a script, free or premium. No FKs, like the ledgers, so the history survives deletions.
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
    "end_reason" "payments"."session_end",
    "unpaid" bigint DEFAULT 0 NOT NULL,
    CONSTRAINT "sessions_price_check" CHECK ("price" >= 0),
    CONSTRAINT "sessions_unpaid_check" CHECK ("unpaid" >= 0),
    CONSTRAINT "sessions_end_check" CHECK (("ended_at" IS NULL) = ("end_reason" IS NULL))
);

COMMENT ON TABLE "payments"."sessions" IS 'Usage sessions. price is fixed when the session starts (0 for free scripts and for the author and tester+). unpaid is the part of a charge the balance could not cover.';

-- Keys

ALTER TABLE ONLY "payments"."sessions"
    ADD CONSTRAINT "sessions_pkey" PRIMARY KEY ("id");

CREATE INDEX "sessions_user_id_idx" ON "payments"."sessions" USING "btree" ("user_id", "started_at" DESC);

CREATE INDEX "sessions_open_last_seen_idx" ON "payments"."sessions" USING "btree" ("last_seen") WHERE ("ended_at" IS NULL);

ALTER TABLE ONLY "payments"."config"
    ADD CONSTRAINT "config_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "payments"."accounts"
    ADD CONSTRAINT "accounts_pkey" PRIMARY KEY ("user_id");

ALTER TABLE ONLY "payments"."accounts"
    ADD CONSTRAINT "accounts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "payments"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "payments"."payments"
    ADD CONSTRAINT "payments_provider_id_key" UNIQUE ("provider", "provider_id");

ALTER TABLE ONLY "payments"."credits_ledger"
    ADD CONSTRAINT "credits_ledger_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "payments"."credits_ledger"
    ADD CONSTRAINT "credits_ledger_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "payments"."payments"("id");

ALTER TABLE ONLY "payments"."earnings_ledger"
    ADD CONSTRAINT "earnings_ledger_pkey" PRIMARY KEY ("id");

CREATE INDEX "payments_user_id_idx" ON "payments"."payments" USING "btree" ("user_id", "created_at" DESC);

CREATE INDEX "credits_ledger_user_id_idx" ON "payments"."credits_ledger" USING "btree" ("user_id", "id" DESC);

CREATE INDEX "earnings_ledger_user_id_idx" ON "payments"."earnings_ledger" USING "btree" ("user_id", "id" DESC);

CREATE INDEX "earnings_ledger_script_id_idx" ON "payments"."earnings_ledger" USING "btree" ("script_id");

-- Functions

-- Appends a credits_ledger row and updates the cached balance. A negative
-- amount that would overdraw the account fails on accounts_credits_check.
CREATE OR REPLACE FUNCTION "payments"."post_credits"(
    "p_user" "uuid", "p_kind" "payments"."credit_kind", "p_amount" bigint,
    "p_payment" "uuid" DEFAULT NULL, "p_script" "uuid" DEFAULT NULL,
    "p_minutes" integer DEFAULT NULL, "p_note" "text" DEFAULT NULL, "p_session" "uuid" DEFAULT NULL
) RETURNS bigint
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

  INSERT INTO payments.credits_ledger (user_id, kind, amount, balance_after, payment_id, script_id, session_id, minutes, note)
  VALUES (p_user, p_kind, p_amount, v_balance, p_payment, p_script, p_session, p_minutes, p_note);

  RETURN v_balance;
END;
$$;


-- Same for the scripter earnings ledger
CREATE OR REPLACE FUNCTION "payments"."post_earnings"(
    "p_user" "uuid", "p_kind" "payments"."earning_kind", "p_amount" bigint,
    "p_script" "uuid" DEFAULT NULL, "p_minutes" integer DEFAULT NULL, "p_note" "text" DEFAULT NULL, "p_session" "uuid" DEFAULT NULL
) RETURNS bigint
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


-- Called by the API when the provider (Bitcart webhook) reports a payment as
-- paid. Idempotent: returns false if it was already settled.
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


-- Balance a user needs to start or keep running a session at p_price. One formula
-- for scripts.can_access, start_session and heartbeat_session.
CREATE OR REPLACE FUNCTION "payments"."required_balance"("p_price" bigint) RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT p_price * min_balance_minutes FROM payments.config;
$$;

-- Charges a session for p_minutes at the price it started with. Internal: only
-- start/heartbeat/end_session call it, with the session row already locked.
-- Debits up to the available balance and records any shortfall in
-- sessions.unpaid instead of overdrawing (sessions of one user share a balance,
-- so a shortfall can still happen, but it stays below one batch). The author
-- gets floor(charged * (10000 - fee_bps) / 10000), the remainder is the platform's.
-- Returns the credits charged.
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

-- Starts a session for the loader (the API calls it with service_role). Fixes
-- the price for the whole session, so later price changes only apply to new
-- sessions, and returns the live revision and its files for the API to hand out
-- as signed URLs.
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

-- Ends a session and charges the started minutes since the last charge, up to
-- last_seen (a run that never got past its first minute still costs one
-- minute). Idempotent. Returns the credits charged.
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

-- Called by the API every 60 seconds while the loader runs. Minutes come from
-- server time, never from the caller. Returns whether the loader may continue.
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

-- Run every minute by pg_cron (see the cron migration): ends the sessions whose
-- loader stopped sending heartbeats. They are charged up to last_seen.
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

-- Scripters move their earnings into their spendable credits. Withdrawals
-- will be a separate, service_role flow on the earnings ledger.
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


-- Trigger functions

CREATE OR REPLACE FUNCTION "payments"."tr_profiles_post_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  INSERT INTO payments.accounts (user_id) VALUES (NEW.id);
  RETURN NEW;
END;
$$;


CREATE OR REPLACE FUNCTION "payments"."tr_ledger_immutable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$;


-- Earnings are money owed to the user, so an account holding any can't be deleted
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

-- Triggers

CREATE OR REPLACE TRIGGER "tr_accounts_pre_delete" BEFORE DELETE ON "payments"."accounts" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_accounts_pre_delete"();

CREATE OR REPLACE TRIGGER "tr_profiles_post_insert" AFTER INSERT ON "profiles"."profiles" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_profiles_post_insert"();

CREATE OR REPLACE TRIGGER "tr_ledger_immutable" BEFORE UPDATE OR DELETE ON "payments"."credits_ledger" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_ledger_immutable"();

CREATE OR REPLACE TRIGGER "tr_ledger_immutable" BEFORE UPDATE OR DELETE ON "payments"."earnings_ledger" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_ledger_immutable"();

CREATE OR REPLACE TRIGGER "tr_ledger_truncate" BEFORE TRUNCATE ON "payments"."credits_ledger" FOR EACH STATEMENT EXECUTE FUNCTION "payments"."tr_ledger_immutable"();

CREATE OR REPLACE TRIGGER "tr_ledger_truncate" BEFORE TRUNCATE ON "payments"."earnings_ledger" FOR EACH STATEMENT EXECUTE FUNCTION "payments"."tr_ledger_immutable"();

-- RLS: users read their own rows; everything else goes through the functions

ALTER TABLE "payments"."config" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "payments"."accounts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "payments"."payments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "payments"."credits_ledger" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "payments"."earnings_ledger" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "payments"."sessions" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for OWNER" ON "payments"."accounts" FOR SELECT TO "authenticated" USING ("user_id" = "profiles"."uid"());

CREATE POLICY "SELECT for OWNER" ON "payments"."payments" FOR SELECT TO "authenticated" USING ("user_id" = "profiles"."uid"());

CREATE POLICY "SELECT for OWNER" ON "payments"."credits_ledger" FOR SELECT TO "authenticated" USING ("user_id" = "profiles"."uid"());

CREATE POLICY "SELECT for OWNER" ON "payments"."sessions" FOR SELECT TO "authenticated" USING ("user_id" = "profiles"."uid"());

CREATE POLICY "SELECT for OWNER" ON "payments"."earnings_ledger" FOR SELECT TO "authenticated" USING ("user_id" = "profiles"."uid"());

-- Privileges

GRANT USAGE ON SCHEMA "payments" TO "authenticated";
GRANT USAGE ON SCHEMA "payments" TO "service_role";

REVOKE ALL ON TABLE "payments"."config", "payments"."accounts", "payments"."payments", "payments"."credits_ledger", "payments"."earnings_ledger", "payments"."sessions" FROM "anon", "authenticated";

GRANT SELECT ON TABLE "payments"."accounts", "payments"."payments", "payments"."credits_ledger", "payments"."earnings_ledger", "payments"."sessions" TO "authenticated";
GRANT ALL ON TABLE "payments"."config", "payments"."payments" TO "service_role";
GRANT SELECT ON TABLE "payments"."accounts", "payments"."credits_ledger", "payments"."earnings_ledger", "payments"."sessions" TO "service_role";

REVOKE ALL ON FUNCTION "payments"."post_credits"("uuid", "payments"."credit_kind", bigint, "uuid", "uuid", integer, "text", "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."post_earnings"("uuid", "payments"."earning_kind", bigint, "uuid", integer, "text", "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."settle_payment"("uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."required_balance"(bigint) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."charge_session"("uuid", integer) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."start_session"("uuid", "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."end_session"("uuid", "payments"."session_end") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."heartbeat_session"("uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."end_stale_sessions"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."transfer_earnings"(bigint) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "payments"."tr_profiles_post_insert"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."tr_ledger_immutable"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."tr_accounts_pre_delete"() FROM PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "payments"."post_credits"("uuid", "payments"."credit_kind", bigint, "uuid", "uuid", integer, "text", "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."post_earnings"("uuid", "payments"."earning_kind", bigint, "uuid", integer, "text", "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."settle_payment"("uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."required_balance"(bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."start_session"("uuid", "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."end_session"("uuid", "payments"."session_end") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."heartbeat_session"("uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."end_stale_sessions"() TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."transfer_earnings"(bigint) TO "authenticated", "service_role";
