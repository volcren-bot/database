-- Schema: info (rewritten for Volcren)
--
-- Legal documents, one row per published version. The old privacy_policy,
-- user_tos and scripter_tos tables (identical shape) are merged into
-- info.documents. The latest version of a kind is the current one.
-- Apply order: public -> profiles -> scripts -> payments -> stats -> info (scripts.can_access reads payments.accounts at call time)


CREATE SCHEMA IF NOT EXISTS "info";

ALTER SCHEMA "info" OWNER TO "postgres";

CREATE TYPE "info"."kind" AS ENUM (
    'privacy_policy',
    'user_tos',
    'scripter_tos'
);


CREATE TABLE IF NOT EXISTS "info"."documents" (
    "kind" "info"."kind" NOT NULL,
    "version" integer NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE ONLY "info"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("kind", "version");

-- Versions count up per kind, starting at 1. Published documents are
-- immutable: there is no UPDATE or DELETE grant.
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

ALTER TABLE "info"."documents" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for EVERYONE" ON "info"."documents" FOR SELECT USING (true);

CREATE POLICY "INSERT for ADMINISTRATOR" ON "info"."documents" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."is_role"('administrator'::"profiles"."roles"));

GRANT USAGE ON SCHEMA "info" TO "anon", "authenticated", "service_role";

REVOKE ALL ON TABLE "info"."documents" FROM "anon", "authenticated";

GRANT SELECT ON TABLE "info"."documents" TO "anon", "authenticated";
GRANT INSERT ("kind", "content") ON TABLE "info"."documents" TO "authenticated";
GRANT ALL ON TABLE "info"."documents" TO "service_role";

REVOKE ALL ON FUNCTION "info"."tr_documents_pre_insert"() FROM PUBLIC, "anon", "authenticated";
