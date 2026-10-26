-- Per-user stats go private: each user's experience, gold, runtime and level totals were readable
-- by everyone, now only by the user and moderator+. Nothing in the webapp read other users' stats.

DROP POLICY IF EXISTS "SELECT for EVERYONE" ON "stats"."stats";

CREATE POLICY "SELECT for OWNER and MODERATOR" ON "stats"."stats" FOR SELECT TO "authenticated" USING ((("id" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));

REVOKE SELECT ON TABLE "stats"."stats" FROM "anon";
