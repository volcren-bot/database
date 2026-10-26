-- Security advisor fixes.
--
-- 1. Public buckets serve objects by URL without any SELECT policy; the policies only let clients list every file.
--    The writes all go through service_role, which bypasses RLS.
-- 2. anon no longer executes helpers that only authenticated policies or the service_role API need. The versions
--    SELECT policy had no TO clause, so it was evaluated for anon and would now fail with a permission error.
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
