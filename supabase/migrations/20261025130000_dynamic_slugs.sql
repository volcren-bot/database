-- Slugs follow title changes and only carry the id suffix on a collision.
-- scripts.slugs remembers every slug a script has had so old links redirect.

CREATE TABLE IF NOT EXISTS "scripts"."slugs" (
    "slug" "text" NOT NULL,
    "id" "uuid" NOT NULL
);

ALTER TABLE ONLY "scripts"."slugs"
    ADD CONSTRAINT "slugs_pkey" PRIMARY KEY ("slug");

ALTER TABLE ONLY "scripts"."slugs"
    ADD CONSTRAINT "slugs_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON DELETE CASCADE;

CREATE INDEX "slugs_id_idx" ON "scripts"."slugs" ("id");

-- Existing scripts keep their current (suffixed) urls; they change on the next rename.
INSERT INTO "scripts"."slugs" ("slug", "id") SELECT "url", "id" FROM "scripts"."scripts";

CREATE OR REPLACE FUNCTION "scripts"."tr_scripts_set_url"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  base text;
  candidate text;
  len integer := 8;
BEGIN
  base := left(trim(both '-' from regexp_replace(lower(NEW.title), '[^a-z0-9]+', '-', 'g')), 80);
  base := trim(both '-' from base);
  IF base = '' THEN base := 'script'; END IF;

  -- Serialise scripts racing for the same slug.
  PERFORM pg_advisory_xact_lock(hashtext(base));

  -- "new" is the create-script route, so it never gets the clean form.
  candidate := base;
  IF base = 'new' OR EXISTS (
    SELECT 1 FROM "scripts"."slugs" WHERE "slug" = candidate AND "id" <> NEW.id
  ) THEN
    LOOP
      candidate := base || '-' || left(NEW.id::text, len);
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM "scripts"."slugs" WHERE "slug" = candidate AND "id" <> NEW.id
      );
      len := len + 4;
    END LOOP;
  END IF;

  NEW.url := candidate;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "scripts"."tr_scripts_record_url"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  INSERT INTO "scripts"."slugs" ("slug", "id") VALUES (NEW.url, NEW.id) ON CONFLICT ("slug") DO NOTHING;
  RETURN NULL;
END;
$$;

DROP TRIGGER "tr_scripts_pre_insert" ON "scripts"."scripts";
DROP FUNCTION "scripts"."tr_scripts_pre_insert"();

CREATE TRIGGER "tr_scripts_pre_insert" BEFORE INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_set_url"();

CREATE TRIGGER "tr_scripts_pre_update" BEFORE UPDATE OF "title" ON "scripts"."scripts" FOR EACH ROW WHEN (OLD."title" IS DISTINCT FROM NEW."title") EXECUTE FUNCTION "scripts"."tr_scripts_set_url"();

CREATE TRIGGER "tr_scripts_record_url" AFTER INSERT OR UPDATE OF "url" ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_record_url"();

ALTER TABLE "scripts"."slugs" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "SELECT for ALLOWED" ON "scripts"."slugs" FOR SELECT USING ("scripts"."can_view"("profiles"."uid"(), "id"));

GRANT SELECT ON TABLE "scripts"."slugs" TO "anon", "authenticated";
GRANT ALL ON TABLE "scripts"."slugs" TO "service_role";

REVOKE ALL ON FUNCTION "scripts"."tr_scripts_set_url"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "scripts"."tr_scripts_record_url"() FROM PUBLIC, "anon", "authenticated";
