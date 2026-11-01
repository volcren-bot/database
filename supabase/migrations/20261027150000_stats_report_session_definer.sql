-- stats.report_session now runs as its owner (SECURITY DEFINER), since service_role has no UPDATE on payments.sessions to lock the row.
ALTER FUNCTION "stats"."report_session"("p_session" "uuid", "p_experience" bigint, "p_gold" bigint, "p_minutes" numeric, "p_custom" bigint[])
    SECURITY DEFINER SET "row_security" TO 'off';
