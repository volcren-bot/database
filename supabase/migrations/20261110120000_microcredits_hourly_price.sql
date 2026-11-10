-- Money moves from credits of 0.01 cent to microcredits (1,000,000 = 1 CREDIT = 1 EUR), and script prices from credits per minute to microcredits per hour, billed as a running total so any hourly price works.

SET local check_function_bodies = off;

ALTER TABLE "payments"."credits_ledger" DISABLE TRIGGER "tr_ledger_immutable";
ALTER TABLE "payments"."earnings_ledger" DISABLE TRIGGER "tr_ledger_immutable";

ALTER TABLE "payments"."accounts" RENAME COLUMN "credits" TO "microcredits";
ALTER TABLE "payments"."accounts" RENAME COLUMN "bonus_credits" TO "bonus_microcredits";
ALTER TABLE "payments"."accounts" RENAME CONSTRAINT "accounts_credits_check" TO "accounts_microcredits_check";
ALTER TABLE "payments"."accounts" RENAME CONSTRAINT "accounts_bonus_credits_check" TO "accounts_bonus_microcredits_check";
ALTER TABLE "payments"."payments" RENAME COLUMN "credits" TO "microcredits";
ALTER TABLE "payments"."payments" RENAME CONSTRAINT "payments_credits_check" TO "payments_microcredits_check";

ALTER TABLE "scripts"."metadata" DROP CONSTRAINT "metadata_price_max_check";
ALTER TABLE "payments"."sessions" DROP CONSTRAINT "sessions_share_check";

UPDATE "payments"."accounts" SET "microcredits" = "microcredits" * 100, "bonus_microcredits" = "bonus_microcredits" * 100, "earnings" = "earnings" * 100;
UPDATE "payments"."payments" SET "microcredits" = "microcredits" * 100, "bonus" = "bonus" * 100;
UPDATE "payments"."credits_ledger" SET "amount" = "amount" * 100, "balance_after" = "balance_after" * 100, "fee" = "fee" * 100, "bonus" = "bonus" * 100;
UPDATE "payments"."earnings_ledger" SET "amount" = "amount" * 100, "balance_after" = "balance_after" * 100, "bonus" = "bonus" * 100;
UPDATE "payments"."config" SET "extra_session_fee" = "extra_session_fee" * 100;
UPDATE "scripts"."metadata" SET "price" = "price" * 6000 WHERE "price" > 0;

DO $$
DECLARE
  v_session payments.sessions;
BEGIN
  FOR v_session IN
    SELECT * FROM payments.sessions s
    WHERE s.ended_at IS NULL AND s.share_accrued >= 100
      AND EXISTS (SELECT 1 FROM payments.accounts a WHERE a.user_id = s.author_id)
  LOOP
    PERFORM payments.post_earnings(v_session.author_id, 'sale', v_session.share_accrued / 100, v_session.script_id, NULL, NULL, v_session.id, 0);
  END LOOP;
END;
$$;

ALTER TABLE "payments"."sessions" ADD COLUMN "charged_minutes" bigint DEFAULT 0 NOT NULL;

UPDATE "payments"."sessions" SET
  "charged_minutes" = round(extract(epoch FROM ("charged_until" - "started_at")) / 60)::bigint,
  "price" = "price" * 6000,
  "unpaid" = "unpaid" * 100,
  "fee_accrued" = "fee_accrued" * 100,
  "fee_charged" = "fee_charged" * 100,
  "share_accrued" = "share_accrued" % 100 * 100;

ALTER TABLE "scripts"."metadata" ADD CONSTRAINT "metadata_price_max_check" CHECK ("price" <= 134400);
ALTER TABLE "payments"."sessions" ADD CONSTRAINT "sessions_share_check" CHECK ("share_accrued" >= 0 AND "share_accrued" < 10000);
ALTER TABLE "payments"."sessions" ADD CONSTRAINT "sessions_charged_minutes_check" CHECK ("charged_minutes" >= 0);
ALTER TABLE "payments"."config" ALTER COLUMN "extra_session_fee" SET DEFAULT 3000000;

ALTER TABLE "payments"."credits_ledger" ENABLE TRIGGER "tr_ledger_immutable";
ALTER TABLE "payments"."earnings_ledger" ENABLE TRIGGER "tr_ledger_immutable";

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

CREATE OR REPLACE FUNCTION "payments"."required_balance"("p_price" bigint) RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT (min_balance_minutes * p_price + 59) / 60 FROM payments.config;
$$;

CREATE OR REPLACE FUNCTION "payments"."required_balance"("p_price" bigint, "p_fee" bigint) RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT payments.required_balance(p_price) + ceil(c.min_balance_minutes * p_fee::numeric / payments.minutes_per_month())::bigint
  FROM payments.config c;
$$;

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
                                                              OR COALESCE((SELECT a.microcredits FROM payments.accounts a WHERE a.user_id = accesser_id), 0) >= payments.required_balance(sc.price)
                                                      )
                                              )
                                      END
                              )
                              )
                      FROM script sc
                      LEFT JOIN viewer v ON true
              ), false);
$$;

COMMENT ON COLUMN "payments"."config"."min_balance_minutes" IS 'A session needs a balance covering this many minutes at its hourly price to start and to keep running (see payments.required_balance).';

COMMENT ON COLUMN "payments"."config"."extra_session_fee" IS 'Microcredits every extra concurrent session of an account costs per 30 days of running (3000000 = 3 EUR). The oldest open session is free, and tester+ pay no fee.';

COMMENT ON COLUMN "payments"."accounts"."microcredits" IS 'Spendable balance in microcredits (1,000,000 = 1 CREDIT = 1 EUR).';

COMMENT ON COLUMN "payments"."accounts"."earnings" IS 'Author earnings in microcredits, owed to the user.';

COMMENT ON COLUMN "payments"."accounts"."bonus_microcredits" IS 'The part of microcredits that came from top-up bonuses. Spent in the same proportion as the balance holds it, and the author''s share on that part is not paid out.';

COMMENT ON COLUMN "payments"."payments"."microcredits" IS 'Microcredits granted when the payment settles, bonus included.';

COMMENT ON COLUMN "payments"."payments"."bonus" IS 'Part of microcredits that is a top-up bonus rather than bought with amount.';

COMMENT ON COLUMN "payments"."payments"."amount" IS 'Amount paid, in the minor unit of currency (cents for EUR). Separate from microcredits so bonuses and other currencies stay possible.';

COMMENT ON COLUMN "payments"."credits_ledger"."amount" IS 'Signed change to the balance, in microcredits.';

COMMENT ON COLUMN "payments"."credits_ledger"."bonus" IS 'The part of amount that moved bonus microcredits, with the sign of amount.';

COMMENT ON COLUMN "payments"."earnings_ledger"."amount" IS 'Signed change to earnings, in microcredits.';

COMMENT ON COLUMN "payments"."earnings_ledger"."bonus" IS 'The part of a sale''s share that was not paid because the buyer paid with bonus microcredits.';

COMMENT ON TABLE "payments"."sessions" IS 'Usage sessions, in microcredits. price is microcredits per hour, fixed when the session starts (0 for free scripts and for the author and tester+); after n charged minutes the script has cost ceil(price x n / 60). unpaid is the part of a charge the balance could not cover. fee_accrued is the extra-session fee owed in microcredit-minutes (a microcredit is charged per 43200), fee_charged the fee microcredits charged so far. charged_minutes counts the minutes billed so far. share_accrued is the author''s share not yet paid, in 1/10000 microcredits: a whole microcredit is paid once it adds up.';

COMMENT ON COLUMN "scripts"."metadata"."price" IS 'Microcredits (1,000,000 = 1 CREDIT = 1 EUR) charged per hour of use, billed by the minute. 0 for free scripts, 1 to 134400 for premium ones: 134400 an hour is 99.99 EUR for a 31-day month of nonstop use, so no script costs more than 100 EUR a month. The maximum is a constant because a CHECK can''t read payments.config.';
