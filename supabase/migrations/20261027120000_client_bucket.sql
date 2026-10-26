-- Hand-written: the `launcher` bucket becomes `client` (loader releases). Supabase can't rename a bucket, so create the
-- new one and move its policies. The row is inserted here for local resets; in production create it in the dashboard
-- first (public) and this insert is skipped. Empty and delete the old `launcher` bucket in the dashboard afterwards:
-- storage refuses to delete a bucket with SQL.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES
    ('client', 'client', true, NULL, NULL)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "launcher INSERT for service_role" ON "storage"."objects";
DROP POLICY IF EXISTS "launcher UPDATE for service_role" ON "storage"."objects";
DROP POLICY IF EXISTS "launcher SELECT for everyone" ON "storage"."objects";

CREATE POLICY "client INSERT for service_role" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'client'::"text"));

CREATE POLICY "client UPDATE for service_role" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'client'::"text")) WITH CHECK (("bucket_id" = 'client'::"text"));

CREATE POLICY "client SELECT for everyone" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'client'::"text"));
