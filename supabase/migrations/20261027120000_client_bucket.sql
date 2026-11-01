-- Hand-written: the `launcher` bucket becomes `client`, since Supabase can't rename one; empty and delete the old bucket in the dashboard.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES
    ('client', 'client', true, NULL, NULL)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "launcher INSERT for service_role" ON "storage"."objects";
DROP POLICY IF EXISTS "launcher UPDATE for service_role" ON "storage"."objects";
DROP POLICY IF EXISTS "launcher SELECT for everyone" ON "storage"."objects";

CREATE POLICY "client INSERT for service_role" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'client'::"text"));

CREATE POLICY "client UPDATE for service_role" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'client'::"text")) WITH CHECK (("bucket_id" = 'client'::"text"));

CREATE POLICY "client SELECT for everyone" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'client'::"text"));
