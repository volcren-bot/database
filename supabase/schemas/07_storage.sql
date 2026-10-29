-- Storage RLS policies; apply after the schemas they call

CREATE POLICY "scripts DELETE for supabase_admin" ON "storage"."objects" FOR DELETE USING ((("bucket_id" = 'scripts'::"text") AND (CURRENT_USER = 'supabase_admin'::"name")));

CREATE POLICY "scripts INSERT for author" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'scripts'::"text") AND "scripts"."can_upload"("name")));

-- Reads: author, moderator+ and, for community scripts, tester+; everyone else gets signed URLs from the API
CREATE POLICY "scripts SELECT for author" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'scripts'::"text") AND ("scripts"."is_object_author"("profiles"."uid"(), "name") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR ("profiles"."min_role"("profiles"."uid"(), 'tester'::"profiles"."roles") AND "scripts"."is_reviewable"("scripts"."safe_uuid"("split_part"("name", '/', 1)))))));

CREATE POLICY "imgs INSERT for author" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "imgs UPDATE for author" ON "storage"."objects" FOR UPDATE USING ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")))) WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "assets INSERT for service_role" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'assets'::"text"));

CREATE POLICY "assets UPDATE for service_role" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'assets'::"text")) WITH CHECK (("bucket_id" = 'assets'::"text"));

CREATE POLICY "client INSERT for service_role" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'client'::"text"));

CREATE POLICY "client UPDATE for service_role" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'client'::"text")) WITH CHECK (("bucket_id" = 'client'::"text"));

-- Public buckets need no SELECT policy; one would only let clients list every file
