-- Fixes slug recording after a rename. tr_scripts_record_url was "AFTER INSERT OR UPDATE OF url",
-- but a rename only sets title (tr_scripts_pre_update picks the new url), and column triggers only
-- fire for columns in the UPDATE's SET list. So renamed slugs were never recorded: old links stopped
-- redirecting and the slug could later go to another script. The update now has its own trigger,
-- with a WHEN that compares the final rows.

DROP TRIGGER "tr_scripts_record_url" ON "scripts"."scripts";

CREATE TRIGGER "tr_scripts_record_url" AFTER INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_record_url"();

CREATE TRIGGER "tr_scripts_record_renamed_url" AFTER UPDATE ON "scripts"."scripts" FOR EACH ROW WHEN (OLD."url" IS DISTINCT FROM NEW."url") EXECUTE FUNCTION "scripts"."tr_scripts_record_url"();

-- Record the current slug of every script renamed while the trigger was broken. Slugs they had in
-- between are lost; one already taken by another script stays with it.
INSERT INTO "scripts"."slugs" ("slug", "id") SELECT "url", "id" FROM "scripts"."scripts" ON CONFLICT ("slug") DO NOTHING;
