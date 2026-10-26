-- Schema: stats (rewritten for Volcren)
--
-- stats.stats       per-user totals, stats.values / stats.values_custom per-script totals,
-- stats.limits(_custom) per-script sanity limits for the reported values,
-- the online counts come from payments.sessions; stats.website(_monthly) download tracking.
-- Rows for a script are created by scripts.tr_scripts_post_insert. Only
-- service_role writes values; authors may edit their script's limits.
--
-- Visibility: only per-user stats (stats.stats) and the online counts
-- (online_count, online_per_script) are public. Everything else is readable
-- only by the script's author and moderator+ (totals: service_role only).
-- Apply order: public -> profiles -> scripts -> payments -> stats -> info (scripts.can_access reads payments.accounts at call time)


CREATE SCHEMA IF NOT EXISTS "stats";

ALTER SCHEMA "stats" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "stats"."get_level"("experience" bigint) RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT floor(experience / (13034431 / 99))::integer;
$$;


CREATE OR REPLACE FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  UPDATE stats.values v
  SET experience = v.experience + add_experience,
      gold       = v.gold + add_gold,
      runtime    = v.runtime + add_runtime
  WHERE v.id = script_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No stats row for script %', script_id USING errcode = 'P0002';
  END IF;
END;
$$;


CREATE OR REPLACE FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  INSERT INTO stats.stats AS s (id, experience, gold, runtime)
  VALUES (user_id, add_experience, add_gold, add_runtime)
  ON CONFLICT (id) DO UPDATE
  SET experience = s.experience + excluded.experience,
      gold       = s.gold + excluded.gold,
      runtime    = s.runtime + excluded.runtime;
$$;


-- Tables

CREATE TABLE IF NOT EXISTS "stats"."limits" (
    "id" "uuid" NOT NULL,
    "xp_min" integer DEFAULT 0 NOT NULL,
    "xp_max" integer DEFAULT 0 NOT NULL,
    "gp_min" bigint DEFAULT 0 NOT NULL,
    "gp_max" bigint DEFAULT 0 NOT NULL
);


CREATE TABLE IF NOT EXISTS "stats"."limits_custom" (
    "id" "uuid" NOT NULL,
    "trackers" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "minima" bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    "maxima" bigint[] DEFAULT '{}'::bigint[] NOT NULL
);


COMMENT ON TABLE "stats"."limits_custom" IS 'Custom script stats';

CREATE TABLE IF NOT EXISTS "stats"."stats" (
    "id" "uuid" NOT NULL,
    "experience" bigint DEFAULT 0 NOT NULL,
    "gold" bigint DEFAULT 0 NOT NULL,
    "runtime" bigint DEFAULT 0 NOT NULL,
    "levels" integer GENERATED ALWAYS AS ("stats"."get_level"("experience")) STORED NOT NULL
);


-- Needs a REFRESH MATERIALIZED VIEW from somewhere (cron/API), it is not refreshed automatically.
CREATE MATERIALIZED VIEW "stats"."totals" AS
 SELECT COALESCE("subquery"."experience", (0)::bigint) AS "experience",
    COALESCE("subquery"."gold", (0)::bigint) AS "gold",
    COALESCE("stats"."get_level"(COALESCE("subquery"."experience", (0)::bigint)), 0) AS "levels",
    COALESCE("subquery"."runtime", (0)::bigint) AS "runtime"
   FROM ( SELECT ("sum"("stats"."experience"))::bigint AS "experience",
            ("sum"("stats"."gold"))::bigint AS "gold",
            ("sum"("stats"."runtime"))::bigint AS "runtime"
           FROM "stats"."stats") "subquery";


CREATE TABLE IF NOT EXISTS "stats"."values" (
    "id" "uuid" NOT NULL,
    "experience" bigint DEFAULT 0 NOT NULL,
    "gold" bigint DEFAULT 0 NOT NULL,
    "runtime" bigint DEFAULT 0 NOT NULL,
    "levels" integer GENERATED ALWAYS AS ("stats"."get_level"("experience")) STORED NOT NULL
);


CREATE TABLE IF NOT EXISTS "stats"."values_custom" (
    "id" "uuid" NOT NULL,
    "values" bigint[] DEFAULT '{}'::bigint[] NOT NULL
);


CREATE TABLE IF NOT EXISTS "stats"."website" (
    "id" "uuid" NOT NULL,
    "downloads" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "total" bigint GENERATED ALWAYS AS (COALESCE("array_length"("downloads", 1), 0)) STORED
);


CREATE TABLE IF NOT EXISTS "stats"."website_monthly" (
    "id" "uuid" NOT NULL,
    "date" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL,
    "downloads" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "total" bigint GENERATED ALWAYS AS (COALESCE("array_length"("downloads", 1), 0)) STORED
);


-- Author of the script or moderator+: who may read its private stats and edit its limits
CREATE OR REPLACE FUNCTION "stats"."can_manage"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT scripts.is_author(profiles.uid(), script_id) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles);
$$;


-- Public online counts, from the open usage sessions (payments.sessions, which is
-- private; these expose numbers only). A session counts as online until its
-- loader has missed heartbeats for session_timeout_minutes.

CREATE OR REPLACE FUNCTION "stats"."online_count"() RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT count(DISTINCT s.user_id)
  FROM payments.sessions s
  WHERE s.ended_at IS NULL
    AND s.last_seen > now() - make_interval(mins => (SELECT c.session_timeout_minutes FROM payments.config c));
$$;

-- Online sessions per script, only for scripts the caller can view. Counted first so can_view
-- runs once per script, not once per session; MATERIALIZED stops the planner pushing it back down.
CREATE OR REPLACE FUNCTION "stats"."online_per_script"() RETURNS TABLE ("script_id" "uuid", "users" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  WITH online AS MATERIALIZED (
    SELECT s.script_id, count(DISTINCT s.user_id) AS users
    FROM payments.sessions s
    WHERE s.ended_at IS NULL
      AND s.last_seen > now() - make_interval(mins => (SELECT c.session_timeout_minutes FROM payments.config c))
    GROUP BY s.script_id
  )
  SELECT o.script_id, o.users
  FROM online o
  WHERE scripts.can_view(profiles.uid(), o.script_id);
$$;

-- Keys

ALTER TABLE ONLY "stats"."limits"
    ADD CONSTRAINT "limits_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "stats"."limits_custom"
    ADD CONSTRAINT "limits_custom_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "stats"."stats"
    ADD CONSTRAINT "stats_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "stats"."values"
    ADD CONSTRAINT "values_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "stats"."values_custom"
    ADD CONSTRAINT "values_custom_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "stats"."website"
    ADD CONSTRAINT "website_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "stats"."website_monthly"
    ADD CONSTRAINT "website_monthly_pkey" PRIMARY KEY ("id", "date");

ALTER TABLE ONLY "stats"."limits"
    ADD CONSTRAINT "limits_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "stats"."limits_custom"
    ADD CONSTRAINT "limits_custom_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "stats"."stats"
    ADD CONSTRAINT "stats_id_fkey" FOREIGN KEY ("id") REFERENCES "profiles"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "stats"."values"
    ADD CONSTRAINT "values_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "stats"."values_custom"
    ADD CONSTRAINT "values_custom_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "stats"."website"
    ADD CONSTRAINT "website_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "stats"."website_monthly"
    ADD CONSTRAINT "website_monthly_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;

-- RLS (service_role bypasses it, so there are no write policies for it)

ALTER TABLE "stats"."limits" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "stats"."limits_custom" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "stats"."stats" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "stats"."values" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "stats"."values_custom" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "stats"."website" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "stats"."website_monthly" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for EVERYONE" ON "stats"."stats" FOR SELECT USING (true);

CREATE POLICY "SELECT for OWNER" ON "stats"."limits" FOR SELECT TO "authenticated" USING ("stats"."can_manage"("id"));

CREATE POLICY "SELECT for OWNER" ON "stats"."limits_custom" FOR SELECT TO "authenticated" USING ("stats"."can_manage"("id"));

CREATE POLICY "SELECT for OWNER" ON "stats"."values" FOR SELECT TO "authenticated" USING ("stats"."can_manage"("id"));

CREATE POLICY "SELECT for OWNER" ON "stats"."values_custom" FOR SELECT TO "authenticated" USING ("stats"."can_manage"("id"));

CREATE POLICY "SELECT for OWNER" ON "stats"."website" FOR SELECT TO "authenticated" USING (("scripts"."is_author"("profiles"."uid"(), "id") OR "profiles"."is_role"("profiles"."uid"(), 'administrator'::"profiles"."roles")));

CREATE POLICY "SELECT for OWNER" ON "stats"."website_monthly" FOR SELECT TO "authenticated" USING (("scripts"."is_author"("profiles"."uid"(), "id") OR "profiles"."is_role"("profiles"."uid"(), 'administrator'::"profiles"."roles")));

CREATE POLICY "UPDATE for OWNER" ON "stats"."limits" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));

CREATE POLICY "UPDATE for OWNER" ON "stats"."limits_custom" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));

-- Privileges

GRANT USAGE ON SCHEMA "stats" TO "anon", "authenticated", "service_role";

REVOKE ALL ON TABLE "stats"."limits", "stats"."limits_custom", "stats"."stats", "stats"."totals", "stats"."values", "stats"."values_custom", "stats"."website", "stats"."website_monthly" FROM "anon", "authenticated";

GRANT SELECT ON TABLE "stats"."stats" TO "anon", "authenticated";
GRANT SELECT ON TABLE "stats"."limits", "stats"."limits_custom", "stats"."values", "stats"."values_custom", "stats"."website", "stats"."website_monthly" TO "authenticated";
GRANT UPDATE ("xp_min", "xp_max", "gp_min", "gp_max") ON TABLE "stats"."limits" TO "authenticated";
GRANT UPDATE ("trackers", "minima", "maxima") ON TABLE "stats"."limits_custom" TO "authenticated";
GRANT ALL ON TABLE "stats"."limits", "stats"."limits_custom", "stats"."stats", "stats"."totals", "stats"."values", "stats"."values_custom", "stats"."website", "stats"."website_monthly" TO "service_role";

REVOKE ALL ON FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) FROM PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "stats"."can_manage"("script_id" "uuid") TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "stats"."online_count"() TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "stats"."online_per_script"() TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "stats"."get_level"("experience" bigint) TO "anon", "authenticated", "service_role";
GRANT EXECUTE ON FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) TO "service_role";
GRANT EXECUTE ON FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) TO "service_role";
