-- Security advisor fixes: drop SELECT policies that only allowed listing public buckets, and stop anon executing authenticated-only helpers.
DROP POLICY IF EXISTS "assets SELECT for everyone" ON "storage"."objects";
DROP POLICY IF EXISTS "client SELECT for everyone" ON "storage"."objects";
DROP POLICY IF EXISTS "imgs SELECT for everyone" ON "storage"."objects";

DROP POLICY IF EXISTS "SELECT for AUTHOR" ON "scripts"."versions";
CREATE POLICY "SELECT for AUTHOR" ON "scripts"."versions" FOR SELECT TO "authenticated"
    USING ("scripts"."is_author"("profiles"."uid"(), "id") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"));

REVOKE ALL ON FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "authenticated", "service_role";
REVOKE ALL ON FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") TO "authenticated", "service_role";
REVOKE ALL ON FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "scripts"."can_access"("accesser_id" "uuid", "script_id" "uuid") TO "service_role";
