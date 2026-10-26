-- Profiles go private: usernames, avatars and roles were readable by everyone, now only by the
-- owner and moderator+. The webapp only showed other people's names as script authors, so those
-- move to scripts.get_authors, which returns the author's username for scripts the caller can view.

DROP POLICY IF EXISTS "SELECT for EVERYONE" ON "profiles"."profiles";

CREATE POLICY "SELECT for OWNER and MODERATOR" ON "profiles"."profiles" FOR SELECT TO "authenticated"
    USING ((("id" = ( SELECT "auth"."uid"() AS "uid")) OR "profiles"."min_role"(( SELECT "auth"."uid"() AS "uid"), 'moderator'::"profiles"."roles")));

REVOKE SELECT ON TABLE "profiles"."profiles" FROM "anon";

CREATE OR REPLACE FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) RETURNS TABLE ("script_id" "uuid", "username" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT p.id, u.username
  FROM scripts.protected p
  JOIN profiles.profiles u ON u.id = p.author
  WHERE p.id = ANY(get_authors.script_ids)
    AND scripts.can_view(profiles.uid(), p.id);
$$;

REVOKE ALL ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "scripts"."get_authors"("script_ids" "uuid"[]) TO "anon", "authenticated", "service_role";
