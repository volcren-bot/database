BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(70);

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

-- Accepts the current terms as the user (the way a client does)
CREATE FUNCTION pg_temp.accept(p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.act(p_id);
  SET LOCAL ROLE authenticated;
  PERFORM info.accept_terms('scripter_tos', (SELECT max(version) FROM info.documents WHERE kind = 'scripter_tos'));
  PERFORM info.accept_terms('community_tos', (SELECT max(version) FROM info.documents WHERE kind = 'community_tos'));
  RESET ROLE;
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'member');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'tester', 'tester');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'mod', 'moderator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'plain');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000005', 'official', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000006', 'grantee');

-- Clients cannot choose a script id; the tests do, inside this rolled-back transaction, to keep ids readable
GRANT INSERT ("id") ON TABLE scripts.scripts TO authenticated;

-- terms gating -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT throws_ok($$INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000001', 'First', 'd', 'c')$$,
  '42501', NULL, 'a user cannot create scripts while no terms are published');
RESET ROLE;

INSERT INTO info.documents (kind, content) VALUES ('scripter_tos', 'scripter terms'), ('community_tos', 'community addendum');

SET LOCAL ROLE authenticated;
SELECT throws_ok($$INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000001', 'First', 'd', 'c')$$,
  '42501', NULL, 'nor before accepting them');
SELECT throws_ok($$SELECT info.accept_terms('community_tos', 2)$$, '23514', 'only the current version can be accepted', 'only the current version can be accepted');
SELECT throws_ok($$SELECT info.accept_terms('user_tos', 1)$$, '23514', NULL, 'only the scripter and community terms are accepted');
SELECT throws_ok($$INSERT INTO info.acceptances (user_id, kind, version) VALUES ('00000000-0000-0000-0000-000000000001', 'scripter_tos', 1)$$,
  '42501', NULL, 'clients cannot write acceptances directly');
SELECT info.accept_terms('community_tos', 1);
SELECT throws_ok($$INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000001', 'First', 'd', 'c')$$,
  '42501', NULL, 'accepting only one of the documents is not enough');
SELECT info.accept_terms('scripter_tos', 1);
SELECT is((SELECT count(*)::int FROM info.acceptances), 2, 'a user reads their acceptances');
SELECT lives_ok($$INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000001', 'First', 'd', 'c')$$,
  'a user who accepted both can create a script');
RESET ROLE;
SELECT is((SELECT role FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000001'), 'contributor'::profiles.roles,
  'the first script makes the user a contributor');
SELECT ok(scripts.author_is_community('10000000-0000-0000-0000-000000000001'), 'a contributor''s script is a community script');

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
SELECT is((SELECT count(*)::int FROM info.acceptances), 0, 'acceptances are private');
RESET ROLE;

-- a new version of a document asks again, existing scripts keep running ----------------
INSERT INTO info.documents (kind, content) VALUES ('community_tos', 'community addendum, second version');

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT throws_ok($$INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000002', 'Second', 'd', 'c')$$,
  '42501', NULL, 'a new version blocks creating scripts');
SELECT throws_ok($$INSERT INTO scripts.versions (id, files, sizes) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau'], ARRAY[10])$$,
  '42501', NULL, 'and uploading revisions');
SELECT throws_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '1 day')$$,
  '42501', NULL, 'and generating share codes');
SELECT is((SELECT count(*)::int FROM scripts.scripts), 1, 'but the existing script is still there');
SELECT info.accept_terms('community_tos', 2);
SELECT lives_ok($$INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000002', 'Second', 'd', 'c')$$,
  'accepting the new version unblocks them');
RESET ROLE;

-- the script limit ------------------------------------------------------------------------
UPDATE scripts.config SET max_community_scripts = 2;
SET LOCAL ROLE authenticated;
SELECT throws_ok($$INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000003', 'Third', 'd', 'c')$$,
  '23514', 'community script limit reached', 'a community author is capped on scripts');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.protected WHERE author = '00000000-0000-0000-0000-000000000001'), 2, 'the refused script left nothing behind');

SELECT pg_temp.accept('00000000-0000-0000-0000-000000000005');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000005');
SELECT lives_ok($$INSERT INTO scripts.scripts (id, title, description, content) VALUES ('20000000-0000-0000-0000-000000000001', 'Official 1', 'd', 'c'), ('20000000-0000-0000-0000-000000000002', 'Official 2', 'd', 'c'), ('20000000-0000-0000-0000-000000000003', 'Official 3', 'd', 'c')$$,
  'a scripter has no script limit');
RESET ROLE;
SELECT is((SELECT role FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000005'), 'scripter'::profiles.roles, 'a scripter stays a scripter');
SELECT ok(NOT scripts.author_is_community('20000000-0000-0000-0000-000000000001'), 'a scripter''s script is official');

-- deleting scripts -----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
DELETE FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000002';
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000002'), 1, 'an author cannot delete their script');

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000003');
DELETE FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000002';
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000002'), 0, 'a moderator can');
SELECT is((SELECT role FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000001'), 'contributor'::profiles.roles, 'a contributor with scripts left stays one');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000003');
DELETE FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000001';
RESET ROLE;
SELECT is((SELECT role FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000001'), 'user'::profiles.roles, 'losing the last script makes a contributor a user again');
UPDATE scripts.config SET max_community_scripts = 50;

-- community scripts are never premium ----------------------------------------------------
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000010', 'Community', 'd', 'c');
SELECT throws_ok($$UPDATE scripts.metadata SET type = 'premium', price = 5 WHERE id = '10000000-0000-0000-0000-000000000010'$$,
  '23514', 'community scripts cannot be premium', 'a community script cannot be premium');
SELECT lives_ok($$UPDATE scripts.metadata SET stage = 'stable' WHERE id = '10000000-0000-0000-0000-000000000010'$$, 'its stage is only a label');
RESET ROLE;

-- promotion unpublishes, demotion makes scripts free --------------------------------------
UPDATE scripts.scripts SET published = true WHERE id = '10000000-0000-0000-0000-000000000010';
UPDATE profiles.profiles SET role = 'scripter' WHERE id = '00000000-0000-0000-0000-000000000001';
SELECT is((SELECT published FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000010'), false, 'a promoted contributor''s scripts are unpublished');
SELECT ok(NOT scripts.author_is_community('10000000-0000-0000-0000-000000000010'), 'and official');

UPDATE scripts.metadata SET type = 'premium', price = 7 WHERE id = '10000000-0000-0000-0000-000000000010';
UPDATE profiles.profiles SET role = 'tester' WHERE id = '00000000-0000-0000-0000-000000000001';
SELECT is((SELECT price FROM scripts.metadata WHERE id = '10000000-0000-0000-0000-000000000010'), 0::bigint, 'a demoted scripter''s premium script becomes free');
SELECT is((SELECT type FROM scripts.metadata WHERE id = '10000000-0000-0000-0000-000000000010'), 'free'::scripts.type, 'with type free');
SELECT is((SELECT role FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000001'), 'tester'::profiles.roles, 'a tester stays a tester');
UPDATE profiles.profiles SET role = 'scripter' WHERE id = '00000000-0000-0000-0000-000000000001';
UPDATE profiles.profiles SET role = 'user' WHERE id = '00000000-0000-0000-0000-000000000001';
SELECT is((SELECT role FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000001'), 'contributor'::profiles.roles, 'a scripter demoted to user with scripts lands on contributor');

-- who sees a community script ---------------------------------------------------------
-- (the author is a contributor again, the script is community, stable and published but has no revision)
UPDATE scripts.scripts SET published = true WHERE id = '10000000-0000-0000-0000-000000000010';
-- a code and grant for the grantee (inserted directly: redeeming is tested in 17_share_codes)
INSERT INTO scripts.share_codes (id, script_id, code_hash, created_by, expires_at, redeemed_by, redeemed_at)
VALUES ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000010', repeat('a', 64), '00000000-0000-0000-0000-000000000001',
        now() + interval '1 day', '00000000-0000-0000-0000-000000000006', now());
INSERT INTO scripts.grants (script_id, user_id, code_id) VALUES ('10000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000006', '30000000-0000-0000-0000-000000000001');

SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000010'), 'the author sees their community script');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000010'), 'a user does not');
SELECT ok(NOT scripts.can_view(NULL, '10000000-0000-0000-0000-000000000010'), 'nor an anonymous visitor');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000010'), 'a tester does');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000010'), 'a moderator does');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000010'), 'a grantee does');

UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000001';
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000010'), 'a banned author no longer sees their script');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000010'), 'a tester does not either');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000010'), 'a grant goes dormant');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000010'), 'but a moderator still does');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SELECT is((SELECT count(*)::int FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000010'), 0, 'the page of a banned author''s script is a 404 for a tester');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000003');
SELECT is((SELECT scripts.author_banned(s) FROM scripts.scripts s WHERE id = '10000000-0000-0000-0000-000000000010'), true, 'moderator+ is told the author is banned');
RESET ROLE;
UPDATE profiles.profiles SET banned_at = NULL WHERE id = '00000000-0000-0000-0000-000000000001';
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000010'), 'unbanning restores the grant');

-- an official script: a grant opens what the stage and published state close ---------------
UPDATE scripts.metadata SET stage = 'prototype' WHERE id = '20000000-0000-0000-0000-000000000001';
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000001'), 'a prototype is hidden from a user');
INSERT INTO scripts.share_codes (id, script_id, code_hash, created_by, expires_at, redeemed_by, redeemed_at)
VALUES ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', repeat('b', 64), '00000000-0000-0000-0000-000000000005',
        now() + interval '1 day', '00000000-0000-0000-0000-000000000006', now());
INSERT INTO scripts.grants (script_id, user_id, code_id) VALUES ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000006', '30000000-0000-0000-0000-000000000002');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000001'), 'but a grantee sees it');
UPDATE scripts.metadata SET stage = 'archived' WHERE id = '20000000-0000-0000-0000-000000000001';
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000001'), 'even archived');

-- running: a live revision is still needed, stages are labels (can_access answers for the caller or service_role)
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);-------------------------
SELECT ok(NOT scripts.can_access('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000010'), 'a grantee cannot run a script without a live revision');
UPDATE scripts.protected SET revision = 1 WHERE id = '10000000-0000-0000-0000-000000000010';
UPDATE scripts.metadata SET stage = 'archived' WHERE id = '10000000-0000-0000-0000-000000000010';
UPDATE scripts.scripts SET published = false WHERE id = '10000000-0000-0000-0000-000000000010';
SELECT ok(scripts.can_access('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000010'), 'a grantee runs a community script whatever its stage and published state');
SELECT ok(scripts.can_access('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000010'), 'so does a tester');
SELECT ok(NOT scripts.can_access('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000010'), 'a user does not');

-- the community storage cap ------------------------------------------------------------------
UPDATE profiles.profiles SET role = 'user' WHERE id = '00000000-0000-0000-0000-000000000001';
DELETE FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000010';
UPDATE scripts.config SET max_community_bytes = 100;

SELECT pg_temp.accept('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000020', 'Capped', 'd', 'c');
SELECT throws_ok($$INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000020', ARRAY['main.luau'])$$,
  '23514', 'every file needs its size', 'a community revision declares its file sizes');
SELECT throws_ok($$INSERT INTO scripts.versions (id, files, sizes) VALUES ('10000000-0000-0000-0000-000000000020', ARRAY['main.luau'], ARRAY[101])$$,
  '23514', 'community storage limit reached', 'a revision over the cap is refused');
SELECT lives_ok($$INSERT INTO scripts.versions (id, files, sizes, entry) VALUES ('10000000-0000-0000-0000-000000000020', ARRAY['main.luau', 'lib.luau'], ARRAY[40, 40], 'main.luau')$$,
  'a revision within the cap is accepted');
RESET ROLE;

-- the pending revision's declared sizes are reserved
SET LOCAL ROLE authenticated;
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000021', 'Other', 'd', 'c');
SELECT throws_ok($$INSERT INTO scripts.versions (id, files, sizes) VALUES ('10000000-0000-0000-0000-000000000021', ARRAY['main.luau'], ARRAY[30])$$,
  '23514', 'community storage limit reached', 'the sizes of another script''s pending revision count');
SELECT lives_ok($$INSERT INTO scripts.versions (id, files, sizes) VALUES ('10000000-0000-0000-0000-000000000021', ARRAY['main.luau'], ARRAY[20])$$,
  'what is left is usable');
RESET ROLE;

-- the declared sizes can lie: publishing checks what was really stored
INSERT INTO storage.objects (bucket_id, name, metadata) VALUES
  ('scripts', '10000000-0000-0000-0000-000000000020/000000001/main.luau', '{"size": 90}'),
  ('scripts', '10000000-0000-0000-0000-000000000020/000000001/lib.luau', '{"size": 10}');
INSERT INTO scripts.version_keys (id, revision, key) VALUES ('10000000-0000-0000-0000-000000000020', 1, decode(repeat('ab', 32), 'hex')), ('10000000-0000-0000-0000-000000000021', 1, decode(repeat('ab', 32), 'hex'));
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000020', 1)$$, 'real sizes that fit let the revision go live');
RESET ROLE;
INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('scripts', '10000000-0000-0000-0000-000000000021/000000001/main.luau', '{"size": 500}');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000021', 1)$$, '23514', 'community storage limit reached',
  'files bigger than declared cannot go live past the cap');
RESET ROLE;
SELECT is((SELECT status FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000021'), 'pending'::scripts.version_status, 'the revision stays pending');
SELECT is(scripts.storage_used('00000000-0000-0000-0000-000000000001'), 600::bigint, 'storage_used counts the real size of every stored file');

-- an official author is not capped, and needs no sizes
SELECT pg_temp.act('00000000-0000-0000-0000-000000000005');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO scripts.versions (id, files) VALUES ('20000000-0000-0000-0000-000000000002', ARRAY['main.luau'])$$, 'a scripter declares no sizes');
RESET ROLE;
INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('scripts', '20000000-0000-0000-0000-000000000002/000000001/main.luau', '{"size": 9999999}');
INSERT INTO scripts.version_keys (id, revision, key) VALUES ('20000000-0000-0000-0000-000000000002', 1, decode(repeat('ab', 32), 'hex'));
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT scripts.publish_version('20000000-0000-0000-0000-000000000002', 1)$$, 'or fit a cap');
RESET ROLE;

-- tester+ read community files -----------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'scripts' AND name LIKE '10000000-0000-0000-0000-000000000020/%'), 2, 'a tester reads the files of a community script');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'scripts' AND name LIKE '20000000-0000-0000-0000-000000000002/%'), 0, 'but not those of an official script');
SELECT is((SELECT count(*)::int FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000020'), 1, 'nor only the files: the revision list too');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'scripts' AND name LIKE '10000000-0000-0000-0000-000000000020/%'), 0, 'a user reads no files');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000006');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'scripts' AND name LIKE '10000000-0000-0000-0000-000000000020/%'), 0, 'nor does a grantee: grants run scripts, they do not read them');
RESET ROLE;
UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'scripts' AND name LIKE '10000000-0000-0000-0000-000000000020/%'), 0, 'a tester loses a banned author''s files');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
