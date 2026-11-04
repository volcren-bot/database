-- Internal script scores and bug reports (schema feedback): tables, the API's service_role functions, the webapp's RLS and helpers, and the daily attachment cleanup.

SET local check_function_bodies = off;

CREATE SCHEMA "feedback";

CREATE TABLE "feedback"."reports" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "script_id"   uuid                     NOT NULL,
  "user_id"     uuid                     NOT NULL,
  "session_id"  uuid                     NOT NULL,
  "revision"    integer                  NOT NULL,
  "description" text                     NOT NULL DEFAULT ''::text,
  "log"         text,
  "snapshot"    jsonb,
  "diagnostics" jsonb,
  "assigned_to" uuid,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "reports_description_check" CHECK ((char_length(description) <= 2000)),
  CONSTRAINT "reports_diagnostics_check" CHECK (((diagnostics IS NULL) OR (pg_column_size(diagnostics) <= 16384))),
  CONSTRAINT "reports_log_check" CHECK (((log IS NULL) OR (octet_length(log) <= 262144))),
  CONSTRAINT "reports_pkey" PRIMARY KEY (id),
  CONSTRAINT "reports_snapshot_check" CHECK (((snapshot IS NULL) OR (pg_column_size(snapshot) <= 65536)))
);

ALTER TABLE "feedback"."reports"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "feedback"."scores" (
  "script_id"  uuid                     NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "session_id" uuid                     NOT NULL,
  "revision"   integer                  NOT NULL,
  "score"      smallint                 NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "scores_pkey" PRIMARY KEY (script_id, user_id),
  CONSTRAINT "scores_score_check" CHECK (((score >= 1) AND (score <= 10)))
);

ALTER TABLE "feedback"."scores"
  ENABLE ROW LEVEL SECURITY;

CREATE TYPE "feedback"."report_status" AS ENUM (
  'open',
  'in_progress',
  'resolved',
  'rejected'
);

ALTER TABLE "feedback"."reports"
  ADD COLUMN "status" feedback.report_status NOT NULL DEFAULT 'open'::feedback.report_status;

CREATE OR REPLACE FUNCTION feedback.can_manage_report (
  r feedback.reports
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT auth.uid() IS NOT NULL AND (
    r.assigned_to = auth.uid()
    OR scripts.is_author(auth.uid(), r.script_id)
    OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  );
$function$;

CREATE OR REPLACE FUNCTION feedback.can_view_report (
  r feedback.reports
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT auth.uid() IS NOT NULL AND (
    r.user_id = auth.uid()
    OR r.assigned_to = auth.uid()
    OR scripts.is_author(auth.uid(), r.script_id)
    OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  );
$function$;

CREATE OR REPLACE FUNCTION feedback.clear_old_attachments()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_count integer;
BEGIN
  UPDATE feedback.reports r SET log = NULL, snapshot = NULL, diagnostics = NULL
  WHERE r.created_at < now() - interval '90 days'
    AND (r.log IS NOT NULL OR r.snapshot IS NOT NULL OR r.diagnostics IS NOT NULL);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION feedback.list_reports (
  p_script uuid DEFAULT NULL::uuid
)
  RETURNS TABLE (
    id              uuid,
    script_id       uuid,
    script_title    text,
    script_url      text,
    user_id         uuid,
    username        text,
    session_id      uuid,
    revision        integer,
    description     text,
    has_log         boolean,
    has_snapshot    boolean,
    has_diagnostics boolean,
    status          feedback.report_status,
    assigned_to     uuid,
    assignee        text,
    created_at      timestamp with time zone,
    updated_at      timestamp with time zone
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT r.id, r.script_id, s.title, s.url, r.user_id, u.username, r.session_id, r.revision, r.description,
    r.log IS NOT NULL, r.snapshot IS NOT NULL, r.diagnostics IS NOT NULL,
    r.status, r.assigned_to, a.username, r.created_at, r.updated_at
  FROM feedback.reports r
  JOIN scripts.scripts s ON s.id = r.script_id
  JOIN profiles.profiles u ON u.id = r.user_id
  LEFT JOIN profiles.profiles a ON a.id = r.assigned_to
  WHERE (p_script IS NULL OR r.script_id = p_script) AND feedback.can_view_report(r)
  ORDER BY r.created_at DESC
  LIMIT 200;
$function$;

CREATE OR REPLACE FUNCTION feedback.list_testers()
  RETURNS TABLE (
    id       uuid,
    username text,
    role     profiles.roles
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT p.id, p.username, p.role
  FROM profiles.profiles p
  WHERE p.role >= 'tester'::profiles.roles AND p.banned_at IS NULL
    AND auth.uid() IS NOT NULL
    AND (profiles.min_role(auth.uid(), 'moderator'::profiles.roles) OR EXISTS (SELECT 1 FROM scripts.protected pr WHERE pr.author = auth.uid()))
  ORDER BY p.username
  LIMIT 200;
$function$;

CREATE OR REPLACE FUNCTION feedback.recent_session (
  p_user    uuid,
  p_session uuid
)
  RETURNS payments.sessions
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
DECLARE
  v_session payments.sessions;
BEGIN
  SELECT * INTO v_session FROM payments.sessions s WHERE s.id = p_session AND s.user_id = p_user;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session not found' USING ERRCODE = 'no_data_found';
  END IF;
  IF COALESCE(v_session.ended_at, now()) < now() - interval '24 hours' THEN
    RAISE EXCEPTION 'session too old' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN v_session;
END;
$function$;

CREATE OR REPLACE FUNCTION feedback.recent_sessions (
  p_user uuid
)
  RETURNS TABLE (
    session_id uuid,
    script_id  uuid,
    title      text,
    url        text,
    revision   integer,
    started_at timestamp with time zone,
    ended_at   timestamp with time zone,
    score      smallint,
    reports    integer
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT s.id, s.script_id, sc.title, sc.url, s.revision, s.started_at, s.ended_at,
    (SELECT f.score FROM feedback.scores f WHERE f.script_id = s.script_id AND f.user_id = p_user),
    (SELECT count(*)::integer FROM feedback.reports r WHERE r.session_id = s.id)
  FROM payments.sessions s
  JOIN scripts.scripts sc ON sc.id = s.script_id
  WHERE s.user_id = p_user AND COALESCE(s.ended_at, now()) >= now() - interval '24 hours'
  ORDER BY s.started_at DESC
  LIMIT 50;
$function$;

CREATE OR REPLACE FUNCTION feedback.report_session (
  p_user        uuid,
  p_session     uuid,
  p_description text,
  p_log         text,
  p_snapshot    jsonb,
  p_diagnostics jsonb
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_session payments.sessions;
  v_id uuid;
BEGIN
  IF profiles.is_banned(p_user) THEN
    RAISE EXCEPTION 'account banned' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_session := feedback.recent_session(p_user, p_session);

  PERFORM pg_advisory_xact_lock(hashtext('feedback.reports.' || p_user::text));
  IF (SELECT count(*) FROM feedback.reports r WHERE r.user_id = p_user AND r.created_at > now() - interval '1 hour') >= 5 THEN
    RAISE EXCEPTION 'too many reports' USING ERRCODE = 'program_limit_exceeded';
  END IF;

  INSERT INTO feedback.reports (script_id, user_id, session_id, revision, description, log, snapshot, diagnostics)
  VALUES (v_session.script_id, p_user, v_session.id, v_session.revision, COALESCE(btrim(p_description), ''), NULLIF(p_log, ''), p_snapshot, p_diagnostics)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION feedback.score_session (
  p_user    uuid,
  p_session uuid,
  p_score   integer
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_session payments.sessions;
BEGIN
  IF profiles.is_banned(p_user) THEN
    RAISE EXCEPTION 'account banned' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_score IS NULL OR p_score < 1 OR p_score > 10 THEN
    RAISE EXCEPTION 'score must be 1 to 10' USING ERRCODE = 'check_violation';
  END IF;

  v_session := feedback.recent_session(p_user, p_session);

  INSERT INTO feedback.scores AS f (script_id, user_id, session_id, revision, score)
  VALUES (v_session.script_id, p_user, v_session.id, v_session.revision, p_score)
  ON CONFLICT (script_id, user_id) DO UPDATE
    SET session_id = EXCLUDED.session_id, revision = EXCLUDED.revision, score = EXCLUDED.score, updated_at = now();
END;
$function$;

CREATE OR REPLACE FUNCTION feedback.score_summary (
  p_script uuid
)
  RETURNS TABLE (
    count     integer,
    average   numeric,
    histogram integer[]
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT (scripts.is_author(auth.uid(), p_script) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    (SELECT count(*)::integer FROM feedback.scores f WHERE f.script_id = p_script),
    (SELECT round(avg(f.score), 2) FROM feedback.scores f WHERE f.script_id = p_script),
    (SELECT array_agg(h.c ORDER BY h.n) FROM (
       SELECT n, (SELECT count(*)::integer FROM feedback.scores f WHERE f.script_id = p_script AND f.score = n) AS c
       FROM generate_series(1, 10) n) h);
END;
$function$;

CREATE OR REPLACE FUNCTION feedback.tr_reports_pre_update()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
BEGIN
  NEW.updated_at := now();
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.id <> OLD.id OR NEW.script_id <> OLD.script_id OR NEW.user_id <> OLD.user_id OR NEW.session_id <> OLD.session_id
    OR NEW.revision <> OLD.revision OR NEW.description <> OLD.description OR NEW.log IS DISTINCT FROM OLD.log
    OR NEW.snapshot IS DISTINCT FROM OLD.snapshot OR NEW.diagnostics IS DISTINCT FROM OLD.diagnostics
    OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'only status and assigned_to can change' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to THEN
    IF NOT (scripts.is_author(auth.uid(), OLD.script_id) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)) THEN
      RAISE EXCEPTION 'only the author or a moderator can assign a report' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.assigned_to IS NOT NULL AND NOT profiles.min_role(NEW.assigned_to, 'tester'::profiles.roles) THEN
      RAISE EXCEPTION 'reports can only be assigned to testers' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

ALTER TABLE "feedback"."reports"
  ADD CONSTRAINT "reports_assigned_to_fkey" FOREIGN KEY (assigned_to) REFERENCES profiles.profiles(id) ON DELETE SET NULL;

ALTER TABLE "feedback"."reports"
  ADD CONSTRAINT "reports_script_id_fkey" FOREIGN KEY (script_id) REFERENCES scripts.scripts(id) ON DELETE CASCADE;

ALTER TABLE "feedback"."reports"
  ADD CONSTRAINT "reports_session_id_fkey" FOREIGN KEY (session_id) REFERENCES payments.sessions(id) ON DELETE CASCADE;

ALTER TABLE "feedback"."reports"
  ADD CONSTRAINT "reports_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles.profiles(id) ON DELETE CASCADE;

ALTER TABLE "feedback"."scores"
  ADD CONSTRAINT "scores_script_id_fkey" FOREIGN KEY (script_id) REFERENCES scripts.scripts(id) ON DELETE CASCADE;

ALTER TABLE "feedback"."scores"
  ADD CONSTRAINT "scores_session_id_fkey" FOREIGN KEY (session_id) REFERENCES payments.sessions(id) ON DELETE CASCADE;

ALTER TABLE "feedback"."scores"
  ADD CONSTRAINT "scores_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles.profiles(id) ON DELETE CASCADE;

CREATE INDEX reports_assigned_to_idx ON feedback.reports USING btree (assigned_to)
  WHERE (assigned_to IS NOT NULL);

CREATE INDEX reports_attachments_idx ON feedback.reports USING btree (created_at)
  WHERE ((log IS NOT NULL) OR (snapshot IS NOT NULL) OR (diagnostics IS NOT NULL));

CREATE INDEX reports_script_id_idx ON feedback.reports USING btree (script_id, created_at DESC);

CREATE INDEX reports_user_id_idx ON feedback.reports USING btree (user_id, created_at DESC);

CREATE TRIGGER tr_reports_pre_update
  BEFORE UPDATE ON feedback.reports
  FOR EACH ROW
  EXECUTE FUNCTION feedback.tr_reports_pre_update();

CREATE POLICY "DELETE for OWNER and MODERATOR" ON "feedback"."reports"
  FOR DELETE
  TO "authenticated"
  USING (((user_id = profiles.uid()) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles)));

CREATE POLICY "SELECT for ALLOWED" ON "feedback"."reports"
  FOR SELECT
  TO "authenticated"
  USING (feedback.can_view_report(reports.*));

CREATE POLICY "UPDATE for ALLOWED" ON "feedback"."reports"
  FOR UPDATE
  TO "authenticated"
  USING (feedback.can_manage_report(reports.*))
  WITH CHECK (feedback.can_manage_report(reports.*));

CREATE POLICY "SELECT for OWNER and MODERATOR" ON "feedback"."scores"
  FOR SELECT
  TO "authenticated"
  USING (((user_id = profiles.uid()) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles)));

COMMENT ON TABLE "feedback"."reports" IS 'Bug reports. Written only by feedback.report_session. Visible to the reporter, the script author, the assigned tester and moderator+; clients may change status and assigned_to only.';

COMMENT ON TABLE "feedback"."scores" IS 'Internal 1-10 scores. Written only by feedback.score_session; authors see aggregates through feedback.score_summary.';

REVOKE ALL ON FUNCTION "feedback"."can_manage_report"(feedback.reports) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."can_manage_report"(feedback.reports) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."can_view_report"(feedback.reports) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."can_view_report"(feedback.reports) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."clear_old_attachments"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."clear_old_attachments"() TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."list_reports"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."list_reports"(uuid) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."list_testers"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."list_testers"() TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."recent_session"(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."recent_session"(uuid, uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."recent_sessions"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."recent_sessions"(uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."report_session"(uuid, uuid, text, text, jsonb, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."report_session"(uuid, uuid, text, text, jsonb, jsonb) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."score_session"(uuid, uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."score_session"(uuid, uuid, integer) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."score_summary"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."score_summary"(uuid) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "feedback"."tr_reports_pre_update"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "feedback"."tr_reports_pre_update"() TO "postgres";

GRANT USAGE ON SCHEMA "feedback" TO "authenticated";

GRANT CREATE, USAGE ON SCHEMA "feedback" TO "postgres";

GRANT USAGE ON SCHEMA "feedback" TO "service_role";

GRANT UPDATE ("assigned_to") ON TABLE "feedback"."reports" TO "authenticated";

GRANT UPDATE ("status") ON TABLE "feedback"."reports" TO "authenticated";

GRANT DELETE, SELECT ON TABLE "feedback"."reports" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "feedback"."reports" TO "postgres", "service_role";

GRANT SELECT ON TABLE "feedback"."scores" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "feedback"."scores" TO "postgres", "service_role";

GRANT USAGE ON TYPE "feedback"."report_status" TO "postgres";

SELECT cron.schedule('feedback-clear-old-attachments', '23 3 * * *', $$SELECT feedback.clear_old_attachments()$$);
