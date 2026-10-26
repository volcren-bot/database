-- stats.report_session locks the session row, which needs UPDATE on payments.sessions. service_role has no
-- such grant (the other session functions are SECURITY DEFINER for that reason), so every report from the
-- API failed with "permission denied for table sessions". Run it as its owner, like they do.
ALTER FUNCTION "stats"."report_session"("p_session" "uuid", "p_experience" bigint, "p_gold" bigint, "p_minutes" numeric, "p_custom" bigint[])
    SECURITY DEFINER SET "row_security" TO 'off';
