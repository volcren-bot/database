-- Record where credits come from: payments.bonus splits the top-up bonus out of payments.credits,
-- and credits_ledger.granted_by records the administrator behind a manual entry. Manual changes go
-- through the new payments.adjust_credits. post_credits gains a trailing p_actor parameter, so the
-- old signature is dropped and its privileges are granted again.

ALTER TABLE "payments"."payments" ADD COLUMN "bonus" bigint DEFAULT 0 NOT NULL;
ALTER TABLE "payments"."payments" ADD CONSTRAINT "payments_bonus_check" CHECK ("bonus" >= 0 AND "bonus" < "credits");
COMMENT ON COLUMN "payments"."payments"."credits" IS 'Credits granted when the payment settles, bonus included.';
COMMENT ON COLUMN "payments"."payments"."bonus" IS 'Part of credits that is a top-up bonus rather than bought with amount.';

ALTER TABLE "payments"."credits_ledger" ADD COLUMN "granted_by" "uuid";

DROP FUNCTION "payments"."post_credits"("uuid", "payments"."credit_kind", bigint, "uuid", "uuid", integer, "text", "uuid");

-- Appends a credits_ledger row and updates the cached balance. A negative
-- amount that would overdraw the account fails on accounts_credits_check.
-- p_actor is the human behind a manual entry (see adjust_credits), null otherwise.
CREATE OR REPLACE FUNCTION "payments"."post_credits"(
    "p_user" "uuid", "p_kind" "payments"."credit_kind", "p_amount" bigint,
    "p_payment" "uuid" DEFAULT NULL, "p_script" "uuid" DEFAULT NULL,
    "p_minutes" integer DEFAULT NULL, "p_note" "text" DEFAULT NULL, "p_session" "uuid" DEFAULT NULL,
    "p_actor" "uuid" DEFAULT NULL
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

  INSERT INTO payments.credits_ledger (user_id, kind, amount, balance_after, payment_id, script_id, session_id, minutes, note, granted_by)
  VALUES (p_user, p_kind, p_amount, v_balance, p_payment, p_script, p_session, p_minutes, p_note, p_actor);

  RETURN v_balance;
END;
$$;

-- Manual change to a balance by an administrator, e.g. a goodwill grant or fixing a mistake.
-- A note is required and the admin is recorded on the ledger row. Called by the API with the
-- service key, which is why the role is checked here and not taken from auth.uid().
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

REVOKE ALL ON FUNCTION "payments"."post_credits"("uuid", "payments"."credit_kind", bigint, "uuid", "uuid", integer, "text", "uuid", "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "payments"."adjust_credits"("uuid", "uuid", bigint, "text") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "payments"."post_credits"("uuid", "payments"."credit_kind", bigint, "uuid", "uuid", integer, "text", "uuid", "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "payments"."adjust_credits"("uuid", "uuid", bigint, "text") TO "service_role";
