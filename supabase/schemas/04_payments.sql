-- Schema payments: append-only credit and earnings ledgers with cached balances


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
    "extra_session_fee" bigint DEFAULT 3000000 NOT NULL,
    CONSTRAINT "config_singleton" CHECK ("id"),
    CONSTRAINT "config_extra_session_fee_check" CHECK ("extra_session_fee" >= 0),
    CONSTRAINT "config_fee_check" CHECK ("platform_fee_bps" BETWEEN 0 AND 10000),
    CONSTRAINT "config_check" CHECK ("session_timeout_minutes" > 0 AND "min_balance_minutes" > 0)
);


COMMENT ON COLUMN "payments"."config"."platform_fee_bps" IS 'Platform cut of each usage charge in basis points (2000 = 20%).';

COMMENT ON COLUMN "payments"."config"."session_timeout_minutes" IS 'A session without a heartbeat for this long is ended with reason timeout.';

COMMENT ON COLUMN "payments"."config"."min_balance_minutes" IS 'A session needs a balance covering this many minutes at its hourly price to start and to keep running (see payments.required_balance).';

COMMENT ON COLUMN "payments"."config"."extra_session_fee" IS 'Microcredits every extra concurrent session of an account costs per 30 days of running (3000000 = 3 EUR). The oldest open session is free, and tester+ pay no fee.';

CREATE TABLE IF NOT EXISTS "payments"."accounts" (
    "user_id" "uuid" NOT NULL,
    "microcredits" bigint DEFAULT 0 NOT NULL,
    "earnings" bigint DEFAULT 0 NOT NULL,
    "bonus_microcredits" bigint DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "accounts_microcredits_check" CHECK ("microcredits" >= 0),
    CONSTRAINT "accounts_earnings_check" CHECK ("earnings" >= 0),
    CONSTRAINT "accounts_bonus_microcredits_check" CHECK ("bonus_microcredits" >= 0 AND "bonus_microcredits" <= "microcredits")
);

COMMENT ON COLUMN "payments"."accounts"."microcredits" IS 'Spendable balance in microcredits (1,000,000 = 1 CREDIT = 1 EUR).';

COMMENT ON COLUMN "payments"."accounts"."earnings" IS 'Author earnings in microcredits, owed to the user.';

COMMENT ON COLUMN "payments"."accounts"."bonus_microcredits" IS 'The part of microcredits that came from top-up bonuses. Spent in the same proportion as the balance holds it, and the author''s share on that part is not paid out.';


CREATE TABLE IF NOT EXISTS "payments"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "provider" "payments"."provider" NOT NULL,
    "provider_id" "text" NOT NULL,
    "status" "payments"."payment_status" DEFAULT 'pending'::"payments"."payment_status" NOT NULL,
    "microcredits" bigint NOT NULL,
    "bonus" bigint DEFAULT 0 NOT NULL,
    "amount" bigint NOT NULL,
    "currency" "text" DEFAULT 'EUR'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "paid_at" timestamp with time zone,
    CONSTRAINT "payments_microcredits_check" CHECK ("microcredits" > 0),
    CONSTRAINT "payments_amount_check" CHECK ("amount" > 0),
    CONSTRAINT "payments_bonus_check" CHECK ("bonus" >= 0 AND "bonus" < "microcredits")
);

COMMENT ON COLUMN "payments"."payments"."microcredits" IS 'Microcredits granted when the payment settles, bonus included.';

COMMENT ON COLUMN "payments"."payments"."bonus" IS 'Part of microcredits that is a top-up bonus rather than bought with amount.';

COMMENT ON COLUMN "payments"."payments"."amount" IS 'Amount paid, in the minor unit of currency (cents for EUR). Separate from microcredits so bonuses and other currencies stay possible.';


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
    "granted_by" "uuid",
    "fee" bigint DEFAULT 0 NOT NULL,
    "bonus" bigint DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "credits_ledger_amount_check" CHECK ("amount" <> 0),
    CONSTRAINT "credits_ledger_fee_check" CHECK ("fee" >= 0 AND ("fee" = 0 OR "fee" <= -"amount")),
    CONSTRAINT "credits_ledger_bonus_check" CHECK (abs("bonus") <= abs("amount") AND ("bonus" = 0 OR sign("bonus") = sign("amount")))
);

COMMENT ON COLUMN "payments"."credits_ledger"."amount" IS 'Signed change to the balance, in microcredits.';

COMMENT ON COLUMN "payments"."credits_ledger"."fee" IS 'The part of a usage charge that is the extra-session fee; the rest is the script''s price.';

COMMENT ON COLUMN "payments"."credits_ledger"."bonus" IS 'The part of amount that moved bonus microcredits, with the sign of amount.';


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
    "bonus" bigint DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "earnings_ledger_amount_check" CHECK ("amount" <> 0 OR "bonus" > 0),
    CONSTRAINT "earnings_ledger_bonus_check" CHECK ("bonus" >= 0)
);

COMMENT ON COLUMN "payments"."earnings_ledger"."amount" IS 'Signed change to earnings, in microcredits.';

COMMENT ON COLUMN "payments"."earnings_ledger"."bonus" IS 'The part of a sale''s share that was not paid because the buyer paid with bonus microcredits.';


-- One row per script run, free or premium; no FKs so history survives deletions
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
    "fee_accrued" bigint DEFAULT 0 NOT NULL,
    "fee_charged" bigint DEFAULT 0 NOT NULL,
    "share_accrued" bigint DEFAULT 0 NOT NULL,
    "charged_minutes" bigint DEFAULT 0 NOT NULL,
    CONSTRAINT "sessions_price_check" CHECK ("price" >= 0),
    CONSTRAINT "sessions_unpaid_check" CHECK ("unpaid" >= 0),
    CONSTRAINT "sessions_fee_check" CHECK ("fee_accrued" >= 0 AND "fee_charged" >= 0),
    CONSTRAINT "sessions_share_check" CHECK ("share_accrued" >= 0 AND "share_accrued" < 10000),
    CONSTRAINT "sessions_charged_minutes_check" CHECK ("charged_minutes" >= 0),
    CONSTRAINT "sessions_end_check" CHECK (("ended_at" IS NULL) = ("end_reason" IS NULL))
);

COMMENT ON TABLE "payments"."sessions" IS 'Usage sessions, in microcredits. price is microcredits per hour, fixed when the session starts (0 for free scripts and for the author and tester+); after n charged minutes the script has cost ceil(price x n / 60). unpaid is the part of a charge the balance could not cover. fee_accrued is the extra-session fee owed in microcredit-minutes (a microcredit is charged per 43200), fee_charged the fee microcredits charged so far. charged_minutes counts the minutes billed so far. share_accrued is the author''s share not yet paid, in 1/10000 microcredits: a whole microcredit is paid once it adds up.';

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

-- The admin page lists staff adjustments, which are rare among the per-minute usage rows
CREATE INDEX "credits_ledger_adjustments_idx" ON "payments"."credits_ledger" USING "btree" ("id" DESC) WHERE ("kind" = 'adjustment'::"payments"."credit_kind");

CREATE INDEX "earnings_ledger_user_id_idx" ON "payments"."earnings_ledger" USING "btree" ("user_id", "id" DESC);

CREATE INDEX "earnings_ledger_script_id_idx" ON "payments"."earnings_ledger" USING "btree" ("script_id");

-- Functions

-- Appends a credits_ledger row and updates the cached balance; overdrawing fails the check
CREATE OR REPLACE FUNCTION "payments"."post_credits"(
    "p_user" "uuid", "p_kind" "payments"."credit_kind", "p_amount" bigint,
    "p_payment" "uuid" DEFAULT NULL, "p_script" "uuid" DEFAULT NULL,
    "p_minutes" integer DEFAULT NULL, "p_note" "text" DEFAULT NULL, "p_session" "uuid" DEFAULT NULL,
    "p_actor" "uuid" DEFAULT NULL, "p_bonus" bigint DEFAULT NULL, "p_fee" bigint DEFAULT 0
) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_account payments.accounts;
  v_bonus bigint;
BEGIN
  SELECT * INTO v_account FROM payments.accounts WHERE user_id = p_user FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no payment account for user %', p_user;
  END IF;

  -- Unless told otherwise, spending takes bonus microcredits in the balance's proportion and gains bring none
  v_bonus := COALESCE(p_bonus, CASE
    WHEN p_amount < 0 AND v_account.microcredits > 0 THEN -(LEAST(-p_amount, v_account.microcredits) * v_account.bonus_microcredits / v_account.microcredits)
    ELSE 0
  END);

  UPDATE payments.accounts
  SET microcredits = microcredits + p_amount, bonus_microcredits = bonus_microcredits + v_bonus, updated_at = now()
  WHERE user_id = p_user
  RETURNING * INTO v_account;

  INSERT INTO payments.credits_ledger (user_id, kind, amount, balance_after, payment_id, script_id, session_id, minutes, note, granted_by, fee, bonus)
  VALUES (p_user, p_kind, p_amount, v_account.microcredits, p_payment, p_script, p_session, p_minutes, p_note, p_actor, p_fee, v_bonus);

  RETURN v_account.microcredits;
END;
$$;


-- Same for the scripter earnings ledger
CREATE OR REPLACE FUNCTION "payments"."post_earnings"(
    "p_user" "uuid", "p_kind" "payments"."earning_kind", "p_amount" bigint,
    "p_script" "uuid" DEFAULT NULL, "p_minutes" integer DEFAULT NULL, "p_note" "text" DEFAULT NULL, "p_session" "uuid" DEFAULT NULL,
    "p_bonus" bigint DEFAULT 0
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

  INSERT INTO payments.earnings_ledger (user_id, kind, amount, balance_after, script_id, session_id, minutes, note, bonus)
  VALUES (p_user, p_kind, p_amount, v_balance, p_script, p_session, p_minutes, p_note, p_bonus);

  RETURN v_balance;
END;
$$;


-- Settles a payment reported paid by the provider; false if already settled
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

  PERFORM payments.post_credits(v_payment.user_id, 'topup', v_payment.microcredits, p_payment, NULL, NULL, NULL, NULL, NULL, v_payment.bonus);

  RETURN true;
END;
$$;


-- Balance needed to start or keep a session at p_price microcredits per hour: min_balance_minutes of it, rounded up
CREATE OR REPLACE FUNCTION "payments"."required_balance"("p_price" bigint) RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT (min_balance_minutes * p_price + 59) / 60 FROM payments.config;
$$;

-- A month of running, the unit extra_session_fee is quoted in
CREATE OR REPLACE FUNCTION "payments"."minutes_per_month"() RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT 30 * 24 * 60;
$$;

-- The balance a session at p_price microcredits per hour with a fee of p_fee microcredits per month needs: min_balance_minutes of both, each rounded up
CREATE OR REPLACE FUNCTION "payments"."required_balance"("p_price" bigint, "p_fee" bigint) RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT payments.required_balance(p_price) + ceil(c.min_balance_minutes * p_fee::numeric / payments.minutes_per_month())::bigint
  FROM payments.config c;
$$;

-- How many of the account's other open sessions started before this one: 0 for the oldest, which runs without a fee
CREATE OR REPLACE FUNCTION "payments"."session_rank"("p_session" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT count(*)::integer
  FROM payments.sessions s
  JOIN payments.sessions o ON o.user_id = s.user_id AND o.ended_at IS NULL AND o.id <> s.id
  WHERE s.id = p_session AND (o.started_at, o.id) < (s.started_at, s.id);
$$;

-- The fee a session of this rank accrues, in microcredits per month: nothing for the oldest session or for tester+
CREATE OR REPLACE FUNCTION "payments"."session_fee"("p_user" "uuid", "p_rank" integer) RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT CASE
    WHEN p_rank >= 1 AND NOT profiles.min_role(p_user, 'tester'::profiles.roles) THEN (SELECT c.extra_session_fee FROM payments.config c)
    ELSE 0
  END;
$$;

-- What starting the script now would cost the user: its price, the rank the session would take, the fee at that rank and the balance needed
CREATE OR REPLACE FUNCTION "payments"."session_quote"("p_user" "uuid", "p_script" "uuid") RETURNS TABLE ("price" bigint, "rank" integer, "fee" bigint, "required" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  WITH open AS (
    SELECT count(*)::integer AS rank FROM payments.sessions s WHERE s.user_id = p_user AND s.ended_at IS NULL
  ), priced AS (
    SELECT CASE
      WHEN p.author = p_user OR profiles.min_role(p_user, 'tester'::profiles.roles) OR scripts.has_grant(p_user, p_script) THEN 0
      ELSE m.price
    END AS price
    FROM scripts.protected p
    JOIN scripts.metadata m ON m.id = p.id
    WHERE p.id = p_script
  )
  SELECT priced.price, open.rank, payments.session_fee(p_user, open.rank), payments.required_balance(priced.price, payments.session_fee(p_user, open.rank))
  FROM priced, open;
$$;

-- Average hourly price of runnable paid scripts, or NULL; definer so it sees all of them
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

-- Internal: charges p_minutes up to the balance, records any shortfall as unpaid, returns microcredits charged
CREATE OR REPLACE FUNCTION "payments"."charge_session"("p_session" "uuid", "p_minutes" integer) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_session payments.sessions;
  v_account payments.accounts;
  v_accrued bigint;
  v_fee_due bigint;
  v_cost bigint;
  v_total bigint;
  v_charged bigint;
  v_fee_paid bigint;
  v_bonus bigint;
  v_share_accrued bigint;
  v_share bigint;
  v_lost bigint;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session % not found', p_session;
  END IF;

  IF p_minutes <= 0 THEN
    RETURN 0;
  END IF;

  -- the fee accrues at the rank the session holds now, and a microcredit is charged for every month's worth of microcredit-minutes
  v_accrued := v_session.fee_accrued + payments.session_fee(v_session.user_id, payments.session_rank(p_session)) * p_minutes;
  v_fee_due := v_accrued / payments.minutes_per_month();
  UPDATE payments.sessions SET fee_accrued = v_accrued % payments.minutes_per_month() WHERE id = p_session;

  v_cost := ((v_session.charged_minutes + p_minutes) * v_session.price + 59) / 60 - (v_session.charged_minutes * v_session.price + 59) / 60;
  UPDATE payments.sessions SET charged_minutes = charged_minutes + p_minutes WHERE id = p_session;
  v_total := v_cost + v_fee_due;

  IF v_total = 0 THEN
    RETURN 0;
  END IF;

  -- lock the account so concurrent sessions can't both spend the same microcredits
  SELECT * INTO v_account FROM payments.accounts WHERE user_id = v_session.user_id FOR UPDATE;

  -- a deleted user can't pay: the whole cost is unpaid
  IF NOT FOUND THEN
    UPDATE payments.sessions SET unpaid = unpaid + v_total WHERE id = p_session;
    RETURN 0;
  END IF;

  v_charged := LEAST(v_total, v_account.microcredits);

  IF v_charged < v_total THEN
    UPDATE payments.sessions SET unpaid = unpaid + (v_total - v_charged) WHERE id = p_session;
  END IF;

  IF v_charged = 0 THEN
    RETURN 0;
  END IF;

  -- the script is paid first, the fee with what is left; bonus microcredits pay their share of the balance
  v_fee_paid := GREATEST(v_charged - v_cost, 0);
  v_bonus := v_charged * v_account.bonus_microcredits / v_account.microcredits;

  PERFORM payments.post_credits(v_session.user_id, 'usage', -v_charged, NULL, v_session.script_id, p_minutes, NULL, p_session, NULL, -v_bonus, v_fee_paid);

  IF v_fee_paid > 0 THEN
    UPDATE payments.sessions SET fee_charged = fee_charged + v_fee_paid WHERE id = p_session;
  END IF;

  -- the author's share is of the script's part only, with fractions of a microcredit carried; the part paid with bonus microcredits is lost
  v_share_accrued := v_session.share_accrued + (v_charged - v_fee_paid) * (10000 - (SELECT platform_fee_bps FROM payments.config));
  v_share := v_share_accrued / 10000;
  UPDATE payments.sessions SET share_accrued = v_share_accrued % 10000 WHERE id = p_session;
  v_lost := v_share * v_bonus / v_charged;

  -- a deleted author has no account: the platform keeps the share
  IF v_share > 0 AND EXISTS (SELECT 1 FROM payments.accounts WHERE user_id = v_session.author_id) THEN
    PERFORM payments.post_earnings(v_session.author_id, 'sale', v_share - v_lost, v_session.script_id, p_minutes, NULL, p_session, v_lost);
  END IF;

  RETURN v_charged;
END;
$$;

-- Starts a session at a fixed price (service_role) and returns the live revision's files
CREATE OR REPLACE FUNCTION "payments"."start_session"("p_user" "uuid", "p_script" "uuid") RETURNS TABLE ("session_id" "uuid", "revision" integer, "files" "text"[], "entry" "text", "rank" integer, "fee" bigint)
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
  v_entry text;
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

  SELECT v.files, v.entry INTO v_files, v_entry FROM scripts.versions v
  WHERE v.id = p_script AND v.revision = v_revision AND v.status = 'live'::scripts.version_status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'script % has no live revision', p_script;
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

  RETURN QUERY SELECT v_id, v_revision, v_files, v_entry, v_rank, v_fee;
END;
$$;

-- Ends a session and charges the minutes since the last charge, at least one; idempotent
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

-- Loader heartbeat; minutes come from server time; returns whether it may continue
CREATE OR REPLACE FUNCTION "payments"."heartbeat_session"("p_session" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_session payments.sessions;
  v_minutes integer;
  v_balance bigint;
  v_required bigint;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session FOR UPDATE;

  IF NOT FOUND OR v_session.ended_at IS NOT NULL THEN
    RETURN false;
  END IF;

  -- A banned author's scripts stop for everyone, running sessions included
  IF scripts.author_is_banned(v_session.script_id) THEN
    PERFORM payments.end_session(p_session, 'stopped');
    RETURN false;
  END IF;

  UPDATE payments.sessions SET last_seen = now() WHERE id = p_session;

  v_minutes := floor(extract(epoch FROM (now() - v_session.charged_until)) / 60)::integer;

  IF v_minutes >= 1 THEN
    PERFORM payments.charge_session(p_session, v_minutes);

    UPDATE payments.sessions SET charged_until = charged_until + make_interval(mins => v_minutes) WHERE id = p_session;
  END IF;

  v_required := payments.required_balance(v_session.price, payments.session_fee(v_session.user_id, payments.session_rank(p_session)));

  IF v_required > 0 THEN
    SELECT microcredits INTO v_balance FROM payments.accounts WHERE user_id = v_session.user_id;

    IF COALESCE(v_balance, 0) < v_required THEN
      PERFORM payments.end_session(p_session, 'insufficient_credits');
      RETURN false;
    END IF;
  END IF;

  RETURN true;
END;
$$;

-- Ends and charges all of a user's running sessions; returns how many
CREATE OR REPLACE FUNCTION "payments"."end_user_sessions"("p_user" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_id uuid;
  v_count integer := 0;
BEGIN
  FOR v_id IN
    SELECT id FROM payments.sessions WHERE user_id = p_user AND ended_at IS NULL
  LOOP
    PERFORM payments.end_session(v_id, 'stopped');
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- Ends a session from the website: its owner or moderator+. The loader stops the script at its next heartbeat, which answers stopped.
CREATE OR REPLACE FUNCTION "payments"."stop_session"("p_session" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_session payments.sessions;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session FOR UPDATE;

  IF NOT FOUND OR auth.uid() IS NULL
     OR NOT (v_session.user_id = auth.uid() OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_session.ended_at IS NOT NULL THEN
    RETURN false;
  END IF;

  PERFORM payments.end_session(p_session, 'stopped');
  RETURN true;
END;
$$;

-- Ends sessions whose loader stopped heartbeating, charged up to last_seen (pg_cron)
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

-- Moves scripter earnings into spendable credits
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


-- Administrator balance adjustment with a required note (service_role, role checked here)
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


-- At most 3 unpaid invoices per user (keep in sync with MAX_PENDING_PAYMENTS in the webapp)
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


-- A deleted account's running scripts are charged up to now while its balance still exists
CREATE OR REPLACE FUNCTION "payments"."tr_profiles_pre_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  PERFORM payments.end_user_sessions(OLD.id);
  RETURN OLD;
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

CREATE OR REPLACE TRIGGER "tr_payments_limit_pending" BEFORE INSERT ON "payments"."payments" FOR EACH ROW WHEN (NEW.status = 'pending') EXECUTE FUNCTION "payments"."tr_payments_limit_pending"();

CREATE OR REPLACE TRIGGER "tr_accounts_pre_delete" BEFORE DELETE ON "payments"."accounts" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_accounts_pre_delete"();

CREATE OR REPLACE TRIGGER "tr_profiles_post_insert" AFTER INSERT ON "profiles"."profiles" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_profiles_post_insert"();

CREATE OR REPLACE TRIGGER "tr_profiles_pre_delete" BEFORE DELETE ON "profiles"."profiles" FOR EACH ROW EXECUTE FUNCTION "payments"."tr_profiles_pre_delete"();

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

REVOKE ALL ON FUNCTION "payments"."post_credits"("uuid", "payments"."credit_kind", bigint, "uuid", "uuid", integer, "text", "uuid", "uuid", bigint, bigint) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."minutes_per_month"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."required_balance"(bigint, bigint) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."session_rank"("uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."session_fee"("uuid", integer) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."session_quote"("uuid", "uuid") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "payments"."minutes_per_month"() TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."required_balance"(bigint, bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."session_rank"("uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."session_fee"("uuid", integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."session_quote"("uuid", "uuid") TO "service_role";
REVOKE ALL ON FUNCTION "payments"."adjust_credits"("uuid", "uuid", bigint, "text") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."post_earnings"("uuid", "payments"."earning_kind", bigint, "uuid", integer, "text", "uuid", bigint) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."settle_payment"("uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."required_balance"(bigint) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."average_price"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."charge_session"("uuid", integer) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."start_session"("uuid", "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."end_session"("uuid", "payments"."session_end") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."heartbeat_session"("uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."end_stale_sessions"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."end_user_sessions"("uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."stop_session"("uuid") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "payments"."tr_profiles_pre_delete"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."transfer_earnings"(bigint) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "payments"."tr_profiles_post_insert"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."tr_ledger_immutable"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."tr_accounts_pre_delete"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."tr_payments_limit_pending"() FROM PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "payments"."post_credits"("uuid", "payments"."credit_kind", bigint, "uuid", "uuid", integer, "text", "uuid", "uuid", bigint, bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."adjust_credits"("uuid", "uuid", bigint, "text") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."post_earnings"("uuid", "payments"."earning_kind", bigint, "uuid", integer, "text", "uuid", bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."settle_payment"("uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."required_balance"(bigint) TO "service_role";
-- The credits page is for logged-in users only
GRANT EXECUTE ON FUNCTION "payments"."average_price"() TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "payments"."start_session"("uuid", "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."end_session"("uuid", "payments"."session_end") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."heartbeat_session"("uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."end_stale_sessions"() TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."transfer_earnings"(bigint) TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "payments"."stop_session"("uuid") TO "authenticated", "service_role";
