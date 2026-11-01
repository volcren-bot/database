-- Fixes slug recording after a rename: column triggers only fire for columns in the SET list, so the update now has its own trigger.

DROP TRIGGER "tr_scripts_record_url" ON "scripts"."scripts";

CREATE TRIGGER "tr_scripts_record_url" AFTER INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_record_url"();

CREATE TRIGGER "tr_scripts_record_renamed_url" AFTER UPDATE ON "scripts"."scripts" FOR EACH ROW WHEN (OLD."url" IS DISTINCT FROM NEW."url") EXECUTE FUNCTION "scripts"."tr_scripts_record_url"();

-- Record the current slug of every script renamed while the trigger was broken; slugs they had in between are lost.
INSERT INTO "scripts"."slugs" ("slug", "id") SELECT "url", "id" FROM "scripts"."scripts" ON CONFLICT ("slug") DO NOTHING;
