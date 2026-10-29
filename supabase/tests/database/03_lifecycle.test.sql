BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(51);

CREATE FUNCTION pg_temp.signup(p_id uuid, p_name text, p_role profiles.roles DEFAULT 'user') RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_name || '@example.com',
          '{"provider":"discord"}', jsonb_build_object('full_name', p_name));
  UPDATE profiles.profiles SET role = p_role WHERE id = p_id;
END;
$$;

CREATE FUNCTION pg_temp.act(p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_id, 'role', 'authenticated')::text, true);
END;
$$;

-- Stub for pg_net (not installed locally) so the webhook trigger can be observed
CREATE SCHEMA IF NOT EXISTS net;
CREATE TABLE public.test_http_log (url text, body jsonb);
CREATE OR REPLACE FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) RETURNS bigint
    LANGUAGE sql AS $$ INSERT INTO public.test_http_log VALUES (url, body); SELECT 1::bigint; $$;
SELECT vault.create_secret('secret', 'WEBHOOK_SECRET');
SELECT vault.create_secret('https://example.com/api', 'WEBHOOK_BASE_URL');

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'other', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'user');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'plain');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000001', 'Mining', 'd', 'c', true);
UPDATE scripts.metadata SET stage = 'stable' WHERE id = '10000000-0000-0000-0000-000000000001';
INSERT INTO scripts.versions (id, files, entry) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau', 'lib.luau'], 'main.luau');

-- revision allocation
SELECT is((SELECT status::text FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001'), 'pending', 'a new revision is pending');
SELECT is((SELECT revision FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001'), 1, 'it gets revision 1');
SELECT is((SELECT revision FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), 0, 'a pending revision does not change protected.revision');
SELECT is((SELECT last_revision FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), 1, 'the allocator moved');
SELECT is((SELECT count(*)::int FROM public.test_http_log), 0, 'inserting a revision fires no webhook');
SELECT throws_ok($$INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['x'])$$, '23505', NULL, 'a second pending revision is rejected');
SELECT is((SELECT can_access FROM (SELECT scripts.can_access('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001')) t(can_access)), false, 'a script without a live revision cannot be run, even by its author');

-- uploads
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT throws_ok($$INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000001/other.luau')$$, '42501', NULL, 'an unlisted file is denied');
SELECT lives_ok($$INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000001/main.luau')$$, 'a listed file of the pending revision is allowed');
SELECT throws_ok($$INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000002/main.luau')$$, '42501', NULL, 'a folder that is not the pending revision is denied');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SELECT throws_ok($$INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000001/lib.luau')$$, '42501', NULL, 'another scripter cannot upload');

-- publishing
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, '42501', 'not allowed', 'another scripter cannot publish');
SELECT throws_ok($$SELECT scripts.set_version_key('10000000-0000-0000-0000-000000000001', 1, repeat('ab', 32))$$, '42501', 'not allowed', 'nor set its key');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT throws_like($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, '%lib.luau%', 'publishing with a missing file fails and names it');
INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000001/lib.luau');
SELECT throws_like($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, '%no encryption key%', 'a revision with no key cannot go live');
SELECT throws_ok($$SELECT scripts.set_version_key('10000000-0000-0000-0000-000000000001', 1, 'abcd')$$, '22023', NULL, 'a key has to be 64 hex digits');
SELECT throws_ok($$SELECT scripts.set_version_key('10000000-0000-0000-0000-000000000001', 1, repeat('AB', 32))$$, '22023', NULL, 'in lowercase');
SELECT throws_ok($$SELECT scripts.set_version_key('10000000-0000-0000-0000-000000000001', 9, repeat('ab', 32))$$, 'P0001', NULL, 'and belong to a pending revision');
SELECT throws_ok($$SELECT key FROM scripts.version_keys$$, '42501', NULL, 'clients cannot read keys');
SELECT lives_ok($$SELECT scripts.set_version_key('10000000-0000-0000-0000-000000000001', 1, repeat('ab', 32))$$, 'the author sets the key');
SELECT throws_ok($$SELECT scripts.set_version_key('10000000-0000-0000-0000-000000000001', 1, repeat('cd', 32))$$, '23505', NULL, 'once');
SELECT lives_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, 'publishing after all uploads succeeds');
RESET ROLE;

SELECT is((SELECT revision FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), 1, 'protected.revision follows the live revision');
SELECT is((SELECT count(*)::int FROM public.test_http_log WHERE url = 'https://example.com/api/scripts/versions'), 1, 'the webhook fired once');
SELECT is((SELECT body #>> '{record,status}' FROM public.test_http_log), 'live', 'with the live record');

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau']);
SELECT throws_ok($$INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000001/lib.luau')$$, '42501', NULL, 'a live revision cannot receive files');
SELECT lives_ok($$SELECT scripts.discard_version('10000000-0000-0000-0000-000000000001', 2)$$, 'a pending revision can be discarded');
SELECT throws_ok($$INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000002/main.luau')$$, '42501', NULL, 'a discarded revision cannot receive files');
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 2)$$, 'P0001', NULL, 'a discarded revision never becomes live');
RESET ROLE;
SELECT is((SELECT revision FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), 1, 'the live revision is unchanged');
INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau']);
SELECT is((SELECT max(revision) FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001'), 3, 'discarded revisions still count for the allocator');

-- a script without a live revision is hidden from everyone but its author
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000002', 'Draft', 'd', 'c', true);
UPDATE scripts.metadata SET stage = 'stable' WHERE id = '10000000-0000-0000-0000-000000000002';
SELECT is(scripts.can_view('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002'), false, 'a script without a live revision is not viewable by users');
SELECT is(scripts.can_view('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002'), true, 'but the author can view it');

-- price limits
SELECT throws_ok($$UPDATE scripts.metadata SET type = 'premium', price = 23 WHERE id = '10000000-0000-0000-0000-000000000002'$$, '23514', NULL, 'a price above the maximum is rejected');
SELECT lives_ok($$UPDATE scripts.metadata SET type = 'premium', price = 22 WHERE id = '10000000-0000-0000-0000-000000000002'$$, 'the maximum price is allowed');

-- entry file
SELECT is((SELECT entry FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND revision = 3), 'main.luau', 'a single file is the entry');
UPDATE scripts.versions SET status = 'discarded' WHERE id = '10000000-0000-0000-0000-000000000001' AND status = 'pending';
INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['bot.luau']);
SELECT is((SELECT entry FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND files = ARRAY['bot.luau']), 'bot.luau', 'the entry needs no particular name');
SELECT throws_ok($$INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['a.luau', 'b.luau'])$$, '22023', NULL, 'several files need an entry');
SELECT throws_ok($$INSERT INTO scripts.versions (id, files, entry) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['a.luau', 'b.luau'], 'c.luau')$$, '23514', NULL, 'the entry has to be one of the files');

-- revision file names
SELECT is(scripts.valid_files(ARRAY['main.luau', 'lib/util.luau', 'a_b-c..d', '.config']), true, 'plain names and subfolders are valid');
SELECT is(scripts.valid_files('{}'), false, 'a revision needs a file');
SELECT is(scripts.valid_files((SELECT array_agg('f' || i) FROM generate_series(1, 50) i)), true, '50 files are allowed');
SELECT is(scripts.valid_files((SELECT array_agg('f' || i) FROM generate_series(1, 51) i)), false, '51 files are not');
SELECT is(scripts.valid_files(ARRAY['main.luau', 'main.luau']), false, 'file names must be unique');
SELECT is((SELECT bool_or(scripts.valid_files(ARRAY[f])) FROM unnest(ARRAY['../x', 'a/../b', '.', 'a/./b', '/a', 'a/', 'a//b', 'a b', 'a\b', 'ä', repeat('a', 201)]) f), false, 'traversal, empty segments, other characters and long names are rejected');
SELECT is(scripts.valid_files(ARRAY[NULL::text]), false, 'a null file name is rejected');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT throws_ok($$INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000002', ARRAY['../escape.luau'])$$, '23514', NULL, 'an author cannot insert a revision with an invalid file name');
RESET ROLE;

-- deleting accounts
SELECT throws_ok($$DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000001'$$, '23503', NULL, 'a user who authors scripts cannot be deleted');
SELECT is((SELECT count(*)::int FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000001'), 1, 'and nothing was deleted');
DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000004';
SELECT is((SELECT count(*)::int FROM profiles.profiles p JOIN payments.accounts a ON a.user_id = p.id WHERE p.id = '00000000-0000-0000-0000-000000000004'), 0, 'a user without scripts is deleted with the profile and the account');
SELECT payments.post_earnings('00000000-0000-0000-0000-000000000003', 'adjustment', 5);
SELECT throws_ok($$DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000003'$$, '23001', NULL, 'a user with earnings cannot be deleted');

SELECT * FROM finish();
ROLLBACK;
