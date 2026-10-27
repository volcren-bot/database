-- RLS policies for Supabase's storage schema (rewritten for Volcren).
-- Apply after the schemas (policies call scripts.* and profiles.* functions).
--
-- Buckets:
--   scripts   <script id>/<9-digit revision>/<file>. Authors upload the listed files of the
--             pending revision only. Clients can't read it except the author, moderator+ and, for
--             community scripts, tester+.
--   imgs      scripts/<script id>/cover.webp and banner.webp, public by URL, author write.
--   assets    public by URL, service_role write.
--   client    public by URL, service_role write (loader releases).

CREATE POLICY "scripts DELETE for supabase_admin" ON "storage"."objects" FOR DELETE USING ((("bucket_id" = 'scripts'::"text") AND (CURRENT_USER = 'supabase_admin'::"name")));

CREATE POLICY "scripts INSERT for author" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'scripts'::"text") AND "scripts"."can_upload"("name")));

-- No client reads the bucket except the author and moderator+ (they review every revision), and
-- tester+ for community scripts. Everyone else gets the files through signed URLs from the API after
-- payments.start_session.
CREATE POLICY "scripts SELECT for author" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'scripts'::"text") AND ("scripts"."is_object_author"("profiles"."uid"(), "name") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR ("profiles"."min_role"("profiles"."uid"(), 'tester'::"profiles"."roles") AND "scripts"."is_reviewable"("scripts"."safe_uuid"("split_part"("name", '/', 1)))))));

CREATE POLICY "imgs INSERT for author" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "imgs UPDATE for author" ON "storage"."objects" FOR UPDATE USING ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")))) WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ((("array_length"("storage"."foldername"("name"), 1) = 2) AND (("storage"."foldername"("name"))[1] = 'scripts'::"text") AND ("storage"."filename"("name") = ANY (ARRAY['cover.webp'::"text", 'banner.webp'::"text"])) AND "scripts"."is_author"("profiles"."uid"(), "scripts"."safe_uuid"(("storage"."foldername"("name"))[2]))) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "assets INSERT for service_role" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'assets'::"text"));

CREATE POLICY "assets UPDATE for service_role" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'assets'::"text")) WITH CHECK (("bucket_id" = 'assets'::"text"));

CREATE POLICY "client INSERT for service_role" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'client'::"text"));

CREATE POLICY "client UPDATE for service_role" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'client'::"text")) WITH CHECK (("bucket_id" = 'client'::"text"));

-- Public buckets need no SELECT policy for object URLs; one would only let clients list every file.
