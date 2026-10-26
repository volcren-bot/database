-- stats.report_session: one entry point for the stats a running session reports.
--
-- It validates the report against the script's per-minute limits (stats.limits and stats.limits_custom) and adds
-- it to the user's totals, the script's totals and the script's custom trackers in one transaction, so a rejected
-- report changes nothing. Until now the API did this with two separate calls and could not store custom trackers.

-- One report from a running session: checks it against the script's per-minute limits and adds it to the
-- user's totals, the script's totals and the script's custom trackers in a single transaction.
-- A rejected report raises (check_violation) and changes nothing.
CREATE OR REPLACE FUNCTION "stats"."report_session"("p_session" "uuid", "p_experience" bigint, "p_gold" bigint, "p_minutes" numeric, "p_custom" bigint[] DEFAULT '{}'::bigint[]) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_session payments.sessions%ROWTYPE;
  v_limits stats.limits%ROWTYPE;
  v_custom stats.limits_custom%ROWTYPE;
  v_runtime bigint;
  v_n integer;
  i integer;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No session %', p_session USING errcode = 'P0002';
  END IF;
  IF v_session.ended_at IS NOT NULL THEN
    RAISE EXCEPTION 'Session % has ended', p_session USING errcode = '55000';
  END IF;

  p_custom := COALESCE(p_custom, '{}'::bigint[]);
  IF p_minutes IS NULL OR p_minutes < 0 OR p_experience IS NULL OR p_experience < 0 OR p_gold IS NULL THEN
    RAISE EXCEPTION 'Invalid report' USING errcode = '22023';
  END IF;
  IF p_experience = 0 AND p_gold = 0 AND NOT EXISTS (SELECT 1 FROM unnest(p_custom) c WHERE c <> 0) THEN
    RAISE EXCEPTION 'Nothing was reported' USING errcode = '22023';
  END IF;

  -- Both bounds 0 means no limit is configured for that value
  SELECT * INTO v_limits FROM stats.limits WHERE id = v_session.script_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No stats limits for script %', v_session.script_id USING errcode = 'P0002';
  END IF;
  IF NOT (v_limits.xp_min = 0 AND v_limits.xp_max = 0)
     AND (p_experience < v_limits.xp_min * p_minutes OR p_experience > v_limits.xp_max * p_minutes) THEN
    RAISE EXCEPTION 'Reported experience is outside the script''s approved limits' USING errcode = '23514';
  END IF;
  IF NOT (v_limits.gp_min = 0 AND v_limits.gp_max = 0)
     AND (p_gold < v_limits.gp_min * p_minutes OR p_gold > v_limits.gp_max * p_minutes) THEN
    RAISE EXCEPTION 'Reported gold is outside the script''s approved limits' USING errcode = '23514';
  END IF;

  SELECT * INTO v_custom FROM stats.limits_custom WHERE id = v_session.script_id;
  v_n := COALESCE(cardinality(p_custom), 0);
  IF v_n > COALESCE(cardinality(v_custom.trackers), 0) THEN
    RAISE EXCEPTION 'More custom values than the script has trackers' USING errcode = '23514';
  END IF;
  FOR i IN 1..v_n LOOP
    IF NOT (COALESCE(v_custom.minima[i], 0) = 0 AND COALESCE(v_custom.maxima[i], 0) = 0)
       AND (p_custom[i] < COALESCE(v_custom.minima[i], 0) * p_minutes
            OR p_custom[i] > COALESCE(v_custom.maxima[i], 0) * p_minutes) THEN
      RAISE EXCEPTION 'Reported custom value % is outside the script''s approved limits', i USING errcode = '23514';
    END IF;
  END LOOP;

  v_runtime := round(p_minutes * 60 * 1000);
  PERFORM stats.increment_script_stats(v_session.script_id, p_experience, p_gold, v_runtime);
  PERFORM stats.increment_user_stats(v_session.user_id, p_experience, p_gold, v_runtime);

  IF v_n > 0 THEN
    -- Element-wise add, growing the stored array to the number of trackers
    UPDATE stats.values_custom vc
    SET "values" = (
      SELECT COALESCE(array_agg(COALESCE(vc."values"[g], 0) + COALESCE(p_custom[g], 0) ORDER BY g), '{}'::bigint[])
      FROM generate_series(1, GREATEST(cardinality(vc."values"), v_n)) g
    )
    WHERE vc.id = v_session.script_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION "stats"."report_session"("p_session" "uuid", "p_experience" bigint, "p_gold" bigint, "p_minutes" numeric, "p_custom" bigint[]) FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "stats"."report_session"("p_session" "uuid", "p_experience" bigint, "p_gold" bigint, "p_minutes" numeric, "p_custom" bigint[]) TO "service_role";
