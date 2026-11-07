-- charge_session dropped the fraction of a credit of the author's share on every charge, so at low prices authors earned less than their share (nothing at price 1); the fraction is now carried in sessions.share_accrued.

SET local check_function_bodies = off;

ALTER TABLE "payments"."sessions"
  ADD COLUMN "share_accrued" bigint NOT NULL DEFAULT 0;

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

  -- the author's share is of the script's part only, with fractions of a credit carried; the part paid with bonus credits is lost
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
$function$;

ALTER TABLE "payments"."sessions"
  ADD CONSTRAINT "sessions_share_check" CHECK (((share_accrued >= 0) AND (share_accrued < 10000)));

COMMENT ON TABLE "payments"."sessions" IS 'Usage sessions. price is fixed when the session starts (0 for free scripts and for the author and tester+). unpaid is the part of a charge the balance could not cover. fee_accrued is the extra-session fee owed in credit-minutes (a credit is charged per 43200), fee_charged the fee credits charged so far. share_accrued is the author''s share not yet paid, in 1/10000 credits: a whole credit is paid once it adds up.';
