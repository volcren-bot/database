-- Schema feedback: internal script scores and bug reports, sent by the loader through the API


CREATE SCHEMA IF NOT EXISTS "feedback";

ALTER SCHEMA "feedback" OWNER TO "postgres";

CREATE TYPE "feedback"."report_status" AS ENUM (
    'open',
    'in_progress',
    'resolved',
    'rejected'
);

-- Tables

-- One score per user per script; scoring again replaces it and remembers the session it was given on
CREATE TABLE IF NOT EXISTS "feedback"."scores" (
    "script_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "session_id" "uuid" NOT NULL,
    "revision" integer NOT NULL,
    "score" smallint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "scores_score_check" CHECK (("score" >= 1) AND ("score" <= 10))
);

COMMENT ON TABLE "feedback"."scores" IS 'Internal 1-10 scores. Written only by feedback.score_session; authors see aggregates through feedback.score_summary.';

-- A bug report on one session; the attachments are cleared after 90 days by clear_old_attachments
CREATE TABLE IF NOT EXISTS "feedback"."reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "script_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "session_id" "uuid" NOT NULL,
    "revision" integer NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "log" "text",
    "snapshot" "jsonb",
    "diagnostics" "jsonb",
    "status" "feedback"."report_status" DEFAULT 'open'::"feedback"."report_status" NOT NULL,
    "assigned_to" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "reports_description_check" CHECK (("char_length"("description") <= 2000)),
    CONSTRAINT "reports_log_check" CHECK ((("log" IS NULL) OR ("octet_length"("log") <= 262144))),
    CONSTRAINT "reports_snapshot_check" CHECK ((("snapshot" IS NULL) OR ("pg_column_size"("snapshot") <= 65536))),
    CONSTRAINT "reports_diagnostics_check" CHECK ((("diagnostics" IS NULL) OR ("pg_column_size"("diagnostics") <= 16384)))
);

COMMENT ON TABLE "feedback"."reports" IS 'Bug reports. Written only by feedback.report_session. Visible to the reporter, the script author, the assigned tester and moderator+; clients may change status and assigned_to only.';

-- Keys

ALTER TABLE ONLY "feedback"."scores"
    ADD CONSTRAINT "scores_pkey" PRIMARY KEY ("script_id", "user_id");

ALTER TABLE ONLY "feedback"."scores"
    ADD CONSTRAINT "scores_script_id_fkey" FOREIGN KEY ("script_id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "feedback"."scores"
    ADD CONSTRAINT "scores_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "feedback"."scores"
    ADD CONSTRAINT "scores_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "payments"."sessions"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "feedback"."reports"
    ADD CONSTRAINT "reports_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "feedback"."reports"
    ADD CONSTRAINT "reports_script_id_fkey" FOREIGN KEY ("script_id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "feedback"."reports"
    ADD CONSTRAINT "reports_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "feedback"."reports"
    ADD CONSTRAINT "reports_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "payments"."sessions"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "feedback"."reports"
    ADD CONSTRAINT "reports_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "profiles"."profiles"("id") ON DELETE SET NULL;

CREATE INDEX "reports_script_id_idx" ON "feedback"."reports" USING "btree" ("script_id", "created_at" DESC);

CREATE INDEX "reports_user_id_idx" ON "feedback"."reports" USING "btree" ("user_id", "created_at" DESC);

CREATE INDEX "reports_assigned_to_idx" ON "feedback"."reports" USING "btree" ("assigned_to") WHERE ("assigned_to" IS NOT NULL);

CREATE INDEX "reports_attachments_idx" ON "feedback"."reports" USING "btree" ("created_at") WHERE (("log" IS NOT NULL) OR ("snapshot" IS NOT NULL) OR ("diagnostics" IS NOT NULL));

-- Functions for the API (service_role)

-- The user's session, if it is theirs and started or ended within the last 24 hours
CREATE OR REPLACE FUNCTION "feedback"."recent_session"("p_user" "uuid", "p_session" "uuid") RETURNS "payments"."sessions"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
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
$$;

-- The user's sessions of the last 24 hours, newest first, with their score of the script and how many reports they sent on each
CREATE OR REPLACE FUNCTION "feedback"."recent_sessions"("p_user" "uuid") RETURNS TABLE ("session_id" "uuid", "script_id" "uuid", "title" "text", "url" "text", "revision" integer, "started_at" timestamp with time zone, "ended_at" timestamp with time zone, "score" smallint, "reports" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT s.id, s.script_id, sc.title, sc.url, s.revision, s.started_at, s.ended_at,
    (SELECT f.score FROM feedback.scores f WHERE f.script_id = s.script_id AND f.user_id = p_user),
    (SELECT count(*)::integer FROM feedback.reports r WHERE r.session_id = s.id)
  FROM payments.sessions s
  JOIN scripts.scripts sc ON sc.id = s.script_id
  WHERE s.user_id = p_user AND COALESCE(s.ended_at, now()) >= now() - interval '24 hours'
  ORDER BY s.started_at DESC
  LIMIT 50;
$$;

-- Scores the session's script 1-10, replacing the user's earlier score of it
CREATE OR REPLACE FUNCTION "feedback"."score_session"("p_user" "uuid", "p_session" "uuid", "p_score" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

-- Files a bug report on the session; at most 5 an hour per user. An empty log is stored as none.
CREATE OR REPLACE FUNCTION "feedback"."report_session"("p_user" "uuid", "p_session" "uuid", "p_description" "text", "p_log" "text", "p_snapshot" "jsonb", "p_diagnostics" "jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

-- Drops the log, snapshot and diagnostics of reports older than 90 days; the rows stay (pg_cron, 00_extensions.sql)
CREATE OR REPLACE FUNCTION "feedback"."clear_old_attachments"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE feedback.reports r SET log = NULL, snapshot = NULL, diagnostics = NULL
  WHERE r.created_at < now() - interval '90 days'
    AND (r.log IS NOT NULL OR r.snapshot IS NOT NULL OR r.diagnostics IS NOT NULL);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Functions for the webapp (authenticated)

-- Whether the caller may read the report: reporter, author, assigned tester or moderator+
CREATE OR REPLACE FUNCTION "feedback"."can_view_report"("r" "feedback"."reports") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT auth.uid() IS NOT NULL AND (
    r.user_id = auth.uid()
    OR r.assigned_to = auth.uid()
    OR scripts.is_author(auth.uid(), r.script_id)
    OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  );
$$;

-- Whether the caller may change the report's status: author, assigned tester or moderator+
CREATE OR REPLACE FUNCTION "feedback"."can_manage_report"("r" "feedback"."reports") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT auth.uid() IS NOT NULL AND (
    r.assigned_to = auth.uid()
    OR scripts.is_author(auth.uid(), r.script_id)
    OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  );
$$;

-- Clients change status and assigned_to only; reassigning takes the author or moderator+, and the assignee must be tester+
CREATE OR REPLACE FUNCTION "feedback"."tr_reports_pre_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
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
$$;

CREATE OR REPLACE TRIGGER "tr_reports_pre_update" BEFORE UPDATE ON "feedback"."reports" FOR EACH ROW EXECUTE FUNCTION "feedback"."tr_reports_pre_update"();

-- Count, average and a 1-10 histogram of a script's scores, for its author or moderator+
CREATE OR REPLACE FUNCTION "feedback"."score_summary"("p_script" "uuid") RETURNS TABLE ("count" integer, "average" numeric, "histogram" integer[])
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

-- The reports the caller may see, newest first and without attachments, with the reporter's and assignee's usernames
CREATE OR REPLACE FUNCTION "feedback"."list_reports"("p_script" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE ("id" "uuid", "script_id" "uuid", "script_title" "text", "script_url" "text", "user_id" "uuid", "username" "text", "session_id" "uuid", "revision" integer, "description" "text", "has_log" boolean, "has_snapshot" boolean, "has_diagnostics" boolean, "status" "feedback"."report_status", "assigned_to" "uuid", "assignee" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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
$$;

-- The testers a report can be assigned to, for script authors and moderator+
CREATE OR REPLACE FUNCTION "feedback"."list_testers"() RETURNS TABLE ("id" "uuid", "username" "text", "role" "profiles"."roles")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT p.id, p.username, p.role
  FROM profiles.profiles p
  WHERE p.role >= 'tester'::profiles.roles AND p.banned_at IS NULL
    AND auth.uid() IS NOT NULL
    AND (profiles.min_role(auth.uid(), 'moderator'::profiles.roles) OR EXISTS (SELECT 1 FROM scripts.protected pr WHERE pr.author = auth.uid()))
  ORDER BY p.username
  LIMIT 200;
$$;

-- RLS

ALTER TABLE "feedback"."scores" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "feedback"."reports" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for OWNER and MODERATOR" ON "feedback"."scores" FOR SELECT TO "authenticated"
    USING (("user_id" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"));

CREATE POLICY "SELECT for ALLOWED" ON "feedback"."reports" FOR SELECT TO "authenticated"
    USING ("feedback"."can_view_report"("reports"));

CREATE POLICY "UPDATE for ALLOWED" ON "feedback"."reports" FOR UPDATE TO "authenticated"
    USING ("feedback"."can_manage_report"("reports")) WITH CHECK ("feedback"."can_manage_report"("reports"));

CREATE POLICY "DELETE for OWNER and MODERATOR" ON "feedback"."reports" FOR DELETE TO "authenticated"
    USING (("user_id" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"));

-- Grants

GRANT USAGE ON SCHEMA "feedback" TO "authenticated", "service_role";

REVOKE ALL ON TABLE "feedback"."scores" FROM "anon", "authenticated";
GRANT SELECT ON TABLE "feedback"."scores" TO "authenticated";
GRANT ALL ON TABLE "feedback"."scores" TO "service_role";

REVOKE ALL ON TABLE "feedback"."reports" FROM "anon", "authenticated";
GRANT SELECT, DELETE ON TABLE "feedback"."reports" TO "authenticated";
GRANT UPDATE ("status", "assigned_to") ON TABLE "feedback"."reports" TO "authenticated";
GRANT ALL ON TABLE "feedback"."reports" TO "service_role";

REVOKE ALL ON FUNCTION "feedback"."recent_session"("p_user" "uuid", "p_session" "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "feedback"."recent_sessions"("p_user" "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "feedback"."score_session"("p_user" "uuid", "p_session" "uuid", "p_score" integer) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "feedback"."report_session"("p_user" "uuid", "p_session" "uuid", "p_description" "text", "p_log" "text", "p_snapshot" "jsonb", "p_diagnostics" "jsonb") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "feedback"."clear_old_attachments"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "feedback"."tr_reports_pre_update"() FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "feedback"."recent_session"("p_user" "uuid", "p_session" "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "feedback"."recent_sessions"("p_user" "uuid") TO "service_role";
GRANT EXECUTE ON FUNCTION "feedback"."score_session"("p_user" "uuid", "p_session" "uuid", "p_score" integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "feedback"."report_session"("p_user" "uuid", "p_session" "uuid", "p_description" "text", "p_log" "text", "p_snapshot" "jsonb", "p_diagnostics" "jsonb") TO "service_role";
GRANT EXECUTE ON FUNCTION "feedback"."clear_old_attachments"() TO "service_role";

-- Called by the policies (TO authenticated)
REVOKE ALL ON FUNCTION "feedback"."can_view_report"("r" "feedback"."reports") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "feedback"."can_manage_report"("r" "feedback"."reports") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "feedback"."score_summary"("p_script" "uuid") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "feedback"."list_reports"("p_script" "uuid") FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "feedback"."list_testers"() FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "feedback"."can_view_report"("r" "feedback"."reports") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "feedback"."can_manage_report"("r" "feedback"."reports") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "feedback"."score_summary"("p_script" "uuid") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "feedback"."list_reports"("p_script" "uuid") TO "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "feedback"."list_testers"() TO "authenticated", "service_role";
