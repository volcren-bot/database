-- Extra concurrent sessions pay a fee: no cap on open sessions, payments.config.extra_session_fee accrues per minute on every session but the account's oldest (tester+ excepted), and bonus credits are tracked so the author's share paid with them is recorded as lost.

SET local check_function_bodies = off;

ALTER TABLE "payments"."earnings_ledger"
  DROP CONSTRAINT "earnings_ledger_amount_check";

DROP FUNCTION "payments"."post_credits"(uuid, payments.credit_kind, bigint, uuid, uuid, integer, text, uuid, uuid);

DROP FUNCTION "payments"."post_earnings"(uuid, payments.earning_kind, bigint, uuid, integer, text, uuid);

DROP FUNCTION "payments"."start_session"(uuid, uuid);

ALTER TABLE "payments"."accounts"
  ADD COLUMN "bonus_credits" bigint NOT NULL DEFAULT 0;

ALTER TABLE "payments"."config"
  ADD COLUMN "extra_session_fee" bigint NOT NULL DEFAULT 30000;

ALTER TABLE "payments"."credits_ledger"
  ADD COLUMN "fee" bigint NOT NULL DEFAULT 0;

ALTER TABLE "payments"."credits_ledger"
  ADD COLUMN "bonus" bigint NOT NULL DEFAULT 0;

ALTER TABLE "payments"."earnings_ledger"
  ADD COLUMN "bonus" bigint NOT NULL DEFAULT 0;

ALTER TABLE "payments"."sessions"
  ADD COLUMN "fee_accrued" bigint NOT NULL DEFAULT 0;

ALTER TABLE "payments"."sessions"
  ADD COLUMN "fee_charged" bigint NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION payments.charge_session (
  p_session uuid,
  p_minutes integer
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
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

  -- the fee accrues at the rank the session holds now, and a credit is charged for every month's worth of credit-minutes
  v_accrued := v_session.fee_accrued + payments.session_fee(v_session.user_id, payments.session_rank(p_session)) * p_minutes;
  v_fee_due := v_accrued / payments.minutes_per_month();
  UPDATE payments.sessions SET fee_accrued = v_accrued % payments.minutes_per_month() WHERE id = p_session;

  v_cost := v_session.price * p_minutes;
  v_total := v_cost + v_fee_due;

  IF v_total = 0 THEN
    RETURN 0;
  END IF;

  -- lock the account so concurrent sessions can't both spend the same credits
  SELECT * INTO v_account FROM payments.accounts WHERE user_id = v_session.user_id FOR UPDATE;

  -- a deleted user can't pay: the whole cost is unpaid
  IF NOT FOUND THEN
    UPDATE payments.sessions SET unpaid = unpaid + v_total WHERE id = p_session;
    RETURN 0;
  END IF;

  v_charged := LEAST(v_total, v_account.credits);

  IF v_charged < v_total THEN
    UPDATE payments.sessions SET unpaid = unpaid + (v_total - v_charged) WHERE id = p_session;
  END IF;

  IF v_charged = 0 THEN
    RETURN 0;
  END IF;

  -- the script is paid first, the fee with what is left; bonus credits pay their share of the balance
  v_fee_paid := GREATEST(v_charged - v_cost, 0);
  v_bonus := v_charged * v_account.bonus_credits / v_account.credits;

  PERFORM payments.post_credits(v_session.user_id, 'usage', -v_charged, NULL, v_session.script_id, p_minutes, NULL, p_session, NULL, -v_bonus, v_fee_paid);

  IF v_fee_paid > 0 THEN
    UPDATE payments.sessions SET fee_charged = fee_charged + v_fee_paid WHERE id = p_session;
  END IF;

  -- the author's share is of the script's part only, and the part paid with bonus credits is lost, not paid
  v_share := (v_charged - v_fee_paid) * (10000 - (SELECT platform_fee_bps FROM payments.config)) / 10000;
  v_lost := v_share * v_bonus / v_charged;

  -- a deleted author has no account: the platform keeps the share
  IF v_share > 0 AND EXISTS (SELECT 1 FROM payments.accounts WHERE user_id = v_session.author_id) THEN
    PERFORM payments.post_earnings(v_session.author_id, 'sale', v_share - v_lost, v_session.script_id, p_minutes, NULL, p_session, v_lost);
  END IF;

  RETURN v_charged;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.heartbeat_session (
  p_session uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
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
    SELECT credits INTO v_balance FROM payments.accounts WHERE user_id = v_session.user_id;

    IF COALESCE(v_balance, 0) < v_required THEN
      PERFORM payments.end_session(p_session, 'insufficient_credits');
      RETURN false;
    END IF;
  END IF;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.minutes_per_month()
  RETURNS integer
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT 30 * 24 * 60;
$function$;

CREATE OR REPLACE FUNCTION payments.post_credits (
  p_user    uuid,
  p_kind    payments.credit_kind,
  p_amount  bigint,
  p_payment uuid                 DEFAULT NULL::uuid,
  p_script  uuid                 DEFAULT NULL::uuid,
  p_minutes integer              DEFAULT NULL::integer,
  p_note    text                 DEFAULT NULL::text,
  p_session uuid                 DEFAULT NULL::uuid,
  p_actor   uuid                 DEFAULT NULL::uuid,
  p_bonus   bigint               DEFAULT NULL::bigint,
  p_fee     bigint               DEFAULT 0
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_account payments.accounts;
  v_bonus bigint;
BEGIN
  SELECT * INTO v_account FROM payments.accounts WHERE user_id = p_user FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no payment account for user %', p_user;
  END IF;

  -- Unless told otherwise, spending takes bonus credits in the balance's proportion and gains bring none
  v_bonus := COALESCE(p_bonus, CASE
    WHEN p_amount < 0 AND v_account.credits > 0 THEN -(LEAST(-p_amount, v_account.credits) * v_account.bonus_credits / v_account.credits)
    ELSE 0
  END);

  UPDATE payments.accounts
  SET credits = credits + p_amount, bonus_credits = bonus_credits + v_bonus, updated_at = now()
  WHERE user_id = p_user
  RETURNING * INTO v_account;

  INSERT INTO payments.credits_ledger (user_id, kind, amount, balance_after, payment_id, script_id, session_id, minutes, note, granted_by, fee, bonus)
  VALUES (p_user, p_kind, p_amount, v_account.credits, p_payment, p_script, p_session, p_minutes, p_note, p_actor, p_fee, v_bonus);

  RETURN v_account.credits;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.post_earnings (
  p_user    uuid,
  p_kind    payments.earning_kind,
  p_amount  bigint,
  p_script  uuid                  DEFAULT NULL::uuid,
  p_minutes integer               DEFAULT NULL::integer,
  p_note    text                  DEFAULT NULL::text,
  p_session uuid                  DEFAULT NULL::uuid,
  p_bonus   bigint                DEFAULT 0
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION payments.required_balance (
  p_price bigint,
  p_fee   bigint
)
  RETURNS bigint
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT c.min_balance_minutes * p_price + ceil(c.min_balance_minutes * p_fee::numeric / payments.minutes_per_month())::bigint
  FROM payments.config c;
$function$;

CREATE OR REPLACE FUNCTION payments.session_fee (
  p_user uuid,
  p_rank integer
)
  RETURNS bigint
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT CASE
    WHEN p_rank >= 1 AND NOT profiles.min_role(p_user, 'tester'::profiles.roles) THEN (SELECT c.extra_session_fee FROM payments.config c)
    ELSE 0
  END;
$function$;

CREATE OR REPLACE FUNCTION payments.session_quote (
  p_user   uuid,
  p_script uuid
)
  RETURNS TABLE (
    price    bigint,
    rank     integer,
    fee      bigint,
    required bigint
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION payments.session_rank (
  p_session uuid
)
  RETURNS integer
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT count(*)::integer
  FROM payments.sessions s
  JOIN payments.sessions o ON o.user_id = s.user_id AND o.ended_at IS NULL AND o.id <> s.id
  WHERE s.id = p_session AND (o.started_at, o.id) < (s.started_at, s.id);
$function$;

CREATE OR REPLACE FUNCTION payments.settle_payment (
  p_payment uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
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

  PERFORM payments.post_credits(v_payment.user_id, 'topup', v_payment.credits, p_payment, NULL, NULL, NULL, NULL, NULL, v_payment.bonus);

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.start_session (
  p_user   uuid,
  p_script uuid
)
  RETURNS TABLE (
    session_id uuid,
    revision   integer,
    files      text[],
    entry      text,
    rank       integer,
    fee        bigint
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
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

  IF v_required > 0 AND COALESCE((SELECT a.credits FROM payments.accounts a WHERE a.user_id = p_user), 0) < v_required THEN
    RAISE EXCEPTION 'insufficient credits' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO payments.sessions AS s (user_id, script_id, author_id, revision, price)
  VALUES (p_user, p_script, v_author, v_revision, v_price)
  RETURNING s.id INTO v_id;

  RETURN QUERY SELECT v_id, v_revision, v_files, v_entry, v_rank, v_fee;
END;
$function$;

ALTER TABLE "payments"."accounts"
  ADD CONSTRAINT "accounts_bonus_credits_check" CHECK (((bonus_credits >= 0) AND (bonus_credits <= credits)));

ALTER TABLE "payments"."config"
  ADD CONSTRAINT "config_extra_session_fee_check" CHECK ((extra_session_fee >= 0));

ALTER TABLE "payments"."credits_ledger"
  ADD CONSTRAINT "credits_ledger_bonus_check" CHECK (((abs(bonus) <= abs(amount)) AND ((bonus = 0) OR (sign((bonus)::double precision) = sign((amount)::double precision)))));

ALTER TABLE "payments"."credits_ledger"
  ADD CONSTRAINT "credits_ledger_fee_check" CHECK (((fee >= 0) AND ((fee = 0) OR (fee <= (- amount)))));

ALTER TABLE "payments"."earnings_ledger"
  ADD CONSTRAINT "earnings_ledger_amount_check" CHECK (((amount <> 0) OR (bonus > 0)));

ALTER TABLE "payments"."earnings_ledger"
  ADD CONSTRAINT "earnings_ledger_bonus_check" CHECK ((bonus >= 0));

ALTER TABLE "payments"."sessions"
  ADD CONSTRAINT "sessions_fee_check" CHECK (((fee_accrued >= 0) AND (fee_charged >= 0)));

COMMENT ON COLUMN "payments"."accounts"."bonus_credits" IS 'The part of credits that came from top-up bonuses. Spent in the same proportion as the balance holds it, and the author''s share on that part is not paid out.';

COMMENT ON COLUMN "payments"."config"."extra_session_fee" IS 'Credits every extra concurrent session of an account costs per 30 days of running (30000 = 1 EUR x 3). The oldest open session is free, and tester+ pay no fee.';

COMMENT ON COLUMN "payments"."credits_ledger"."bonus" IS 'The part of amount that moved bonus credits, with the sign of amount.';

COMMENT ON COLUMN "payments"."credits_ledger"."fee" IS 'The part of a usage charge that is the extra-session fee; the rest is the script''s price.';

COMMENT ON COLUMN "payments"."earnings_ledger"."bonus" IS 'The part of a sale''s share that was not paid because the buyer paid with bonus credits.';

COMMENT ON TABLE "payments"."sessions" IS 'Usage sessions. price is fixed when the session starts (0 for free scripts and for the author and tester+). unpaid is the part of a charge the balance could not cover. fee_accrued is the extra-session fee owed in credit-minutes (a credit is charged per 43200), fee_charged the fee credits charged so far.';

REVOKE ALL ON FUNCTION "payments"."minutes_per_month"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."minutes_per_month"() TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."post_credits"(uuid, payments.credit_kind, bigint, uuid, uuid, integer, text, uuid, uuid, bigint, bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."post_credits"(uuid, payments.credit_kind, bigint, uuid, uuid, integer, text, uuid, uuid, bigint, bigint) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."post_earnings"(uuid, payments.earning_kind, bigint, uuid, integer, text, uuid, bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."post_earnings"(uuid, payments.earning_kind, bigint, uuid, integer, text, uuid, bigint) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."required_balance"(bigint, bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."required_balance"(bigint, bigint) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."session_fee"(uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."session_fee"(uuid, integer) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."session_quote"(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."session_quote"(uuid, uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."session_rank"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."session_rank"(uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."start_session"(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."start_session"(uuid, uuid) TO "postgres", "service_role";

-- Existing balances: count the bonus of settled top-ups as bonus credits, capped by what is left
UPDATE payments.accounts a
SET bonus_credits = LEAST(a.credits, COALESCE((SELECT sum(p.bonus) FROM payments.payments p WHERE p.user_id = a.user_id AND p.status = 'paid'), 0));
