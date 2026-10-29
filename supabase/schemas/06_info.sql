-- Schema info: legal documents, one row per published version (the latest is current)


CREATE SCHEMA IF NOT EXISTS "info";

ALTER SCHEMA "info" OWNER TO "postgres";

CREATE TYPE "info"."kind" AS ENUM (
    'privacy_policy',
    'user_tos',
    'scripter_tos',
    'community_tos'
);


CREATE TABLE IF NOT EXISTS "info"."documents" (
    "kind" "info"."kind" NOT NULL,
    "version" integer NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE ONLY "info"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("kind", "version");

-- Which document version each user accepted, written only by accept_terms
CREATE TABLE IF NOT EXISTS "info"."acceptances" (
    "user_id" "uuid" NOT NULL,
    "kind" "info"."kind" NOT NULL,
    "version" integer NOT NULL,
    "accepted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "info"."acceptances"
    ADD CONSTRAINT "acceptances_pkey" PRIMARY KEY ("user_id", "kind", "version");

ALTER TABLE ONLY "info"."acceptances"
    ADD CONSTRAINT "acceptances_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "info"."acceptances"
    ADD CONSTRAINT "acceptances_document_fkey" FOREIGN KEY ("kind", "version") REFERENCES "info"."documents"("kind", "version");

-- Versions count up per kind from 1; published documents are immutable
CREATE OR REPLACE FUNCTION "info"."tr_documents_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('info.documents.' || NEW.kind::text));

  SELECT COALESCE(max(version), 0) + 1 INTO NEW.version FROM info.documents WHERE kind = NEW.kind;

  RETURN NEW;
END;
$$;


CREATE OR REPLACE TRIGGER "tr_documents_pre_insert" BEFORE INSERT ON "info"."documents" FOR EACH ROW EXECUTE FUNCTION "info"."tr_documents_pre_insert"();

-- Accepts the current scripter_tos or community_tos version; repeating changes nothing
CREATE OR REPLACE FUNCTION "info"."accept_terms"("p_kind" "info"."kind", "p_version" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_kind NOT IN ('scripter_tos'::info.kind, 'community_tos'::info.kind) THEN
    RAISE EXCEPTION 'only the scripter and community terms are accepted' USING ERRCODE = 'check_violation';
  END IF;

  IF p_version IS DISTINCT FROM (SELECT max(d.version) FROM info.documents d WHERE d.kind = p_kind) THEN
    RAISE EXCEPTION 'only the current version can be accepted' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO info.acceptances (user_id, kind, version) VALUES (auth.uid(), p_kind, p_version)
  ON CONFLICT DO NOTHING;
END;
$$;

ALTER TABLE "info"."documents" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "info"."acceptances" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for EVERYONE" ON "info"."documents" FOR SELECT USING (true);

CREATE POLICY "INSERT for ADMINISTRATOR" ON "info"."documents" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."is_role"('administrator'::"profiles"."roles"));

-- Users read their own acceptances
CREATE POLICY "SELECT for OWNER" ON "info"."acceptances" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));

GRANT USAGE ON SCHEMA "info" TO "anon", "authenticated", "service_role";

REVOKE ALL ON TABLE "info"."documents" FROM "anon", "authenticated";

GRANT SELECT ON TABLE "info"."documents" TO "anon", "authenticated";
GRANT INSERT ("kind", "content") ON TABLE "info"."documents" TO "authenticated";
GRANT ALL ON TABLE "info"."documents" TO "service_role";

REVOKE ALL ON FUNCTION "info"."tr_documents_pre_insert"() FROM PUBLIC, "anon", "authenticated";

REVOKE ALL ON TABLE "info"."acceptances" FROM "anon", "authenticated";
GRANT SELECT ON TABLE "info"."acceptances" TO "authenticated";
GRANT ALL ON TABLE "info"."acceptances" TO "service_role";

REVOKE ALL ON FUNCTION "info"."accept_terms"("p_kind" "info"."kind", "p_version" integer) FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "info"."accept_terms"("p_kind" "info"."kind", "p_version" integer) TO "authenticated", "service_role";
