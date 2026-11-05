-- Lets a session's owner or moderator+ end it from the website (payments.stop_session); the loader stops the script at its next heartbeat.

SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION payments.stop_session (
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
$function$;

REVOKE ALL ON FUNCTION "payments"."stop_session"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."stop_session"(uuid) TO "authenticated", "postgres", "service_role";
