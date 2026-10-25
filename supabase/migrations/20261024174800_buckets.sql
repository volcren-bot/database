-- Hand-written: bucket rows are data, which the schema files cannot hold.
-- [storage.buckets.*] in config.toml only applies to the local stack.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES
    ('scripts',  'scripts',  false, 5 * 1024 * 1024, NULL),
    ('imgs',     'imgs',     true,  2 * 1024 * 1024, ARRAY['image/webp']),
    ('assets',   'assets',   true,  NULL,            NULL),
    ('launcher', 'launcher', true,  NULL,            NULL)
ON CONFLICT (id) DO NOTHING;
