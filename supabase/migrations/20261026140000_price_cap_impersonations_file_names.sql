-- Three hardening changes:
--  1. Script prices are capped at 22 credits a minute (about 98 EUR for a 31-day month of
--     nonstop use) instead of 10,000. Prices above the new cap are lowered to it.
--  2. Admin impersonations are recorded in the append-only profiles.impersonations, and
--     administrators can no longer impersonate each other (profiles.log_impersonation).
--  3. versions.files is checked in the database (count, uniqueness, allowed characters, no
--     "." or ".." segments) instead of only in the browser.

-- 1. price cap --------------------------------------------------------------------------

UPDATE "scripts"."metadata" SET "price" = 22 WHERE "price" > 22;

ALTER TABLE "scripts"."metadata" DROP CONSTRAINT "metadata_price_max_check";
ALTER TABLE "scripts"."metadata" ADD CONSTRAINT "metadata_price_max_check" CHECK ("price" <= 22);

COMMENT ON COLUMN "scripts"."metadata"."price" IS 'Credits (1 credit = 0.01 cent EUR, 10,000 credits = 1 EUR) charged per minute of use. 0 for free scripts, 1 to 22 for premium ones: 22 a minute is about 98 EUR for a 31-day month of nonstop use, so no script costs more than 100 EUR a month. The maximum is a constant because a CHECK can''t read payments.config.';

-- 2. impersonation log ------------------------------------------------------------------

CREATE TABLE "profiles"."impersonations" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "admin_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "profiles"."impersonations"
    ADD CONSTRAINT "impersonations_pkey" PRIMARY KEY ("id");

CREATE OR REPLACE FUNCTION "profiles"."log_impersonation"("p_admin" "uuid", "p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF p_admin IS NULL OR NOT profiles.is_role(p_admin, 'administrator') THEN
    RAISE EXCEPTION 'only administrators can impersonate' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles.profiles WHERE id = p_user) THEN
    RAISE EXCEPTION 'user % not found', p_user USING ERRCODE = 'no_data_found';
  END IF;

  IF profiles.min_role(p_user, 'administrator') THEN
    RAISE EXCEPTION 'administrators cannot be impersonated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO profiles.impersonations (admin_id, user_id) VALUES (p_admin, p_user);
END;
$$;

CREATE OR REPLACE FUNCTION "profiles"."tr_impersonations_immutable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER "tr_impersonations_immutable" BEFORE UPDATE OR DELETE ON "profiles"."impersonations" FOR EACH ROW EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();

CREATE TRIGGER "tr_impersonations_truncate" BEFORE TRUNCATE ON "profiles"."impersonations" FOR EACH STATEMENT EXECUTE FUNCTION "profiles"."tr_impersonations_immutable"();

ALTER TABLE "profiles"."impersonations" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "profiles"."impersonations" FROM "anon", "authenticated", "service_role";
GRANT SELECT ON TABLE "profiles"."impersonations" TO "service_role";

REVOKE ALL ON FUNCTION "profiles"."log_impersonation"("p_admin" "uuid", "p_user" "uuid") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "profiles"."tr_impersonations_immutable"() FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "profiles"."log_impersonation"("p_admin" "uuid", "p_user" "uuid") TO "service_role";

-- 3. revision file names ----------------------------------------------------------------
-- Fails if an existing revision breaks the new rules; find those with:
--   select id, revision, files from scripts.versions where not scripts.valid_files(files);
-- (run after creating the function below, or inside a transaction you roll back).

CREATE OR REPLACE FUNCTION "scripts"."valid_files"("files" "text"[]) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT cardinality(files) BETWEEN 1 AND 50
    AND cardinality(files) = (SELECT count(DISTINCT f) FROM unnest(files) f)
    AND NOT EXISTS (
      SELECT 1 FROM unnest(files) f
      WHERE f IS NULL
         OR char_length(f) > 200
         OR f !~ '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$'
         OR f ~ '(^|/)\.\.?(/|$)'
    );
$$;

REVOKE ALL ON FUNCTION "scripts"."valid_files"("files" "text"[]) FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "scripts"."valid_files"("files" "text"[]) TO "authenticated", "service_role";

ALTER TABLE "scripts"."versions" DROP CONSTRAINT "versions_files_check";
ALTER TABLE "scripts"."versions" ADD CONSTRAINT "versions_files_check" CHECK ("scripts"."valid_files"("files"));
