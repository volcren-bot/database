-- A user can have at most 3 unpaid invoices at once, so the checkout form can't be used to flood
-- Bitcart. The webapp checks first and reuses an open invoice; this is the backstop for
-- simultaneous requests.

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

CREATE OR REPLACE TRIGGER "tr_payments_limit_pending" BEFORE INSERT ON "payments"."payments" FOR EACH ROW WHEN (NEW.status = 'pending') EXECUTE FUNCTION "payments"."tr_payments_limit_pending"();

REVOKE ALL ON FUNCTION "payments"."tr_payments_limit_pending"() FROM PUBLIC, "anon", "authenticated";
