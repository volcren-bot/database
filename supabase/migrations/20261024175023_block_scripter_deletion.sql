SET local check_function_bodies = off;

ALTER TABLE "scripts"."protected"
  DROP CONSTRAINT "protected_author_fkey";

CREATE OR REPLACE FUNCTION payments.tr_accounts_pre_delete()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
BEGIN
  IF OLD.earnings > 0 THEN
    RAISE EXCEPTION 'account % still has earnings to pay out', OLD.user_id USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN OLD;
END;
$function$;

ALTER TABLE "scripts"."protected"
  ADD CONSTRAINT "protected_author_fkey" FOREIGN KEY (author) REFERENCES profiles.profiles(id) ON DELETE RESTRICT;

CREATE TRIGGER tr_accounts_pre_delete
  BEFORE DELETE ON payments.accounts
  FOR EACH ROW
  EXECUTE FUNCTION payments.tr_accounts_pre_delete();

REVOKE ALL ON FUNCTION "payments"."tr_accounts_pre_delete"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."tr_accounts_pre_delete"() TO "postgres";
