SET local check_function_bodies = off;

CREATE TABLE "profiles"."scripter_applications" (
  "id"         bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "message"    text                     NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  "decided_at" timestamp with time zone,
  "decided_by" uuid,
  "reason"     text,
  CONSTRAINT "scripter_applications_message_check" CHECK (((message = btrim(message)) AND ((char_length(message) >= 1) AND (char_length(message) <= 2000)))),
  CONSTRAINT "scripter_applications_pkey" PRIMARY KEY (id),
  CONSTRAINT "scripter_applications_reason_check" CHECK (((reason IS NULL) OR ((reason = btrim(reason)) AND ((char_length(reason) >= 1) AND (char_length(reason) <= 500)))))
);

ALTER TABLE "profiles"."scripter_applications"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "scripts"."config"
  ADD COLUMN "scripter_min_scripts" integer NOT NULL DEFAULT 3;

ALTER TABLE "scripts"."config"
  ADD COLUMN "scripter_min_users" integer NOT NULL DEFAULT 5;

ALTER TABLE "scripts"."config"
  ADD COLUMN "scripter_min_minutes" integer NOT NULL DEFAULT 10;

ALTER TABLE "scripts"."config"
  ADD COLUMN "scripter_reapply_days" integer NOT NULL DEFAULT 30;

CREATE TYPE "profiles"."application_status" AS ENUM (
  'pending',
  'approved',
  'rejected'
);

ALTER TABLE "profiles"."scripter_applications"
  ADD COLUMN "status" profiles.application_status NOT NULL DEFAULT 'pending'::profiles.application_status;

CREATE OR REPLACE FUNCTION profiles.apply_for_scripter (
  p_message text
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_id bigint;
BEGIN
  IF v_user IS NULL OR NOT EXISTS (
    SELECT 1 FROM profiles.profiles p
    WHERE p.id = v_user AND p.role = 'contributor'::profiles.roles AND p.banned_at IS NULL
  ) THEN
    RAISE EXCEPTION 'only contributors can apply' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT profiles.is_scripter_eligible(v_user) THEN
    RAISE EXCEPTION 'not enough scripts with users yet' USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (
    SELECT 1 FROM profiles.scripter_applications a
    WHERE a.user_id = v_user AND a.status = 'rejected'::profiles.application_status
      AND a.decided_at > now() - make_interval(days => (SELECT c.scripter_reapply_days FROM scripts.config c))
  ) THEN
    RAISE EXCEPTION 'rejected too recently' USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  INSERT INTO profiles.scripter_applications (user_id, message) VALUES (v_user, btrim(p_message))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION profiles.decide_scripter_application (
  p_admin       uuid,
  p_application bigint,
  p_approve     boolean,
  p_reason      text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_user uuid;
  v_reason text := NULLIF(btrim(p_reason), '');
BEGIN
  IF p_admin IS NULL OR NOT profiles.is_role(p_admin, 'administrator') THEN
    RAISE EXCEPTION 'only administrators decide applications' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_approve IS NULL THEN
    RAISE EXCEPTION 'p_approve must not be null';
  END IF;

  IF NOT p_approve AND v_reason IS NULL THEN
    RAISE EXCEPTION 'a reason is required to reject';
  END IF;

  SELECT a.user_id INTO v_user FROM profiles.scripter_applications a
  WHERE a.id = p_application AND a.status = 'pending'::profiles.application_status
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no pending application %', p_application USING ERRCODE = 'no_data_found';
  END IF;

  IF p_approve THEN
    UPDATE profiles.profiles SET role = 'scripter'::profiles.roles
    WHERE id = v_user AND role = 'contributor'::profiles.roles AND banned_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'the applicant is no longer an unbanned contributor' USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END IF;

  UPDATE profiles.scripter_applications
  SET status = CASE WHEN p_approve THEN 'approved'::profiles.application_status ELSE 'rejected'::profiles.application_status END,
      decided_at = now(), decided_by = p_admin, reason = v_reason
  WHERE id = p_application;
END;
$function$;

CREATE OR REPLACE FUNCTION profiles.is_scripter_eligible (
  p_user uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  RETURN (
    SELECT count(*) FROM profiles.scripter_progress(p_user) g
    WHERE g.users >= (SELECT c.scripter_min_users FROM scripts.config c)
  ) >= (SELECT c.scripter_min_scripts FROM scripts.config c);
END;
$function$;

CREATE OR REPLACE FUNCTION profiles.scripter_progress (
  p_user uuid
)
  RETURNS TABLE (
    script_id uuid,
    users     integer
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  IF auth.role() <> 'service_role' AND p_user IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'only your own progress' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT p.id, (
    SELECT count(DISTINCT s.user_id)::integer
    FROM payments.sessions s
    JOIN profiles.profiles u ON u.id = s.user_id
    WHERE s.script_id = p.id
      AND s.user_id <> p_user
      AND u.banned_at IS NULL
      AND s.charged_minutes >= (SELECT c.scripter_min_minutes FROM scripts.config c)
  )
  FROM scripts.protected p
  WHERE p.author = p_user;
END;
$function$;

ALTER TABLE "profiles"."scripter_applications"
  ADD CONSTRAINT "scripter_applications_decided_check"
    CHECK
    ((((status = 'pending'::profiles.application_status) = (decided_at IS NULL)) AND ((decided_at IS NULL) = (decided_by IS NULL)) AND ((status <>
    'rejected'::profiles.application_status) OR (reason IS NOT NULL))));

ALTER TABLE "profiles"."scripter_applications"
  ADD CONSTRAINT "scripter_applications_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles.profiles(id) ON DELETE CASCADE;

ALTER TABLE "scripts"."config"
  ADD CONSTRAINT "config_scripter_check" CHECK (((scripter_min_scripts > 0) AND (scripter_min_users > 0) AND (scripter_min_minutes > 0) AND (scripter_reapply_days >= 0)));

CREATE INDEX sessions_script_id_idx ON payments.sessions USING btree (script_id, user_id);

CREATE UNIQUE INDEX scripter_applications_one_pending_idx ON profiles.scripter_applications USING btree (user_id)
  WHERE (status = 'pending'::profiles.application_status);

CREATE INDEX scripter_applications_user_id_idx ON profiles.scripter_applications USING btree (user_id, created_at DESC);

CREATE POLICY "SELECT for OWNER" ON "profiles"."scripter_applications"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

COMMENT ON COLUMN "scripts"."config"."scripter_min_minutes" IS 'Billed minutes one session needs for its user to count towards scripter_min_users.';

COMMENT ON COLUMN "scripts"."config"."scripter_min_scripts" IS 'Scripts with scripter_min_users users a contributor needs to apply for scripter (profiles.apply_for_scripter).';

COMMENT ON COLUMN "scripts"."config"."scripter_min_users" IS 'Distinct other, unbanned users a script needs to count towards scripter_min_scripts.';

COMMENT ON COLUMN "scripts"."config"."scripter_reapply_days" IS 'Days after a rejected scripter application before the contributor can apply again.';

COMMENT ON TABLE "profiles"."scripter_applications" IS 'Written only by profiles.apply_for_scripter and profiles.decide_scripter_application. decided_by has no FK so the record outlives the admin.';

REVOKE ALL ON FUNCTION "profiles"."apply_for_scripter"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "profiles"."apply_for_scripter"(text) TO "authenticated", "postgres";

REVOKE ALL ON FUNCTION "profiles"."decide_scripter_application"(uuid, bigint, boolean, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "profiles"."decide_scripter_application"(uuid, bigint, boolean, text) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "profiles"."is_scripter_eligible"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "profiles"."is_scripter_eligible"(uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "profiles"."scripter_progress"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "profiles"."scripter_progress"(uuid) TO "authenticated", "postgres", "service_role";

GRANT SELECT ON TABLE "profiles"."scripter_applications" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "profiles"."scripter_applications" TO "postgres";

GRANT SELECT ON TABLE "profiles"."scripter_applications" TO "service_role";

GRANT USAGE ON TYPE "profiles"."application_status" TO "postgres";
