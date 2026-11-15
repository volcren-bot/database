BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(30);

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

CREATE FUNCTION pg_temp.upload(p_script uuid, p_revision integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO scripts.versions (id, files) VALUES (p_script, ARRAY['main.luau']);
  INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', p_script::text || '/' || lpad(p_revision::text, 9, '0') || '/main.luau');
  INSERT INTO scripts.version_keys (id, revision, key) VALUES (p_script, p_revision, decode(repeat('ab', 32), 'hex'));
END;
$$;

CREATE FUNCTION pg_temp.problems() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '[{"file": "main.luau", "line": 3, "column": 14, "message": "Key ''form'' not found in table"}]'::jsonb;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'player');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'moderator', 'moderator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'grantee');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000005', 'tester', 'tester');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000001', 'Bosses', 'd', 'c', true);
UPDATE scripts.metadata SET stage = 'stable';
INSERT INTO scripts.share_codes (id, script_id, code_hash, created_by, expires_at, redeemed_by, redeemed_at)
VALUES ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', repeat('a', 64), '00000000-0000-0000-0000-000000000001', now() + interval '1 day', '00000000-0000-0000-0000-000000000004', now());
INSERT INTO scripts.grants (script_id, user_id, code_id) VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', '30000000-0000-0000-0000-000000000001');
SELECT pg_temp.upload('10000000-0000-0000-0000-000000000001', 1);

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-abc1234', 22, NULL)$$, '42501', NULL, 'an author cannot record a check');
SELECT throws_ok($$UPDATE scripts.versions SET checked_lib = 'x', checked_host = 0, checked_at = now() WHERE id = '10000000-0000-0000-0000-000000000001'$$, '42501', NULL, 'nor write the check columns');
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, '23514', 'revision 1 of script 10000000-0000-0000-0000-000000000001 has not passed the script check', 'an unchecked revision cannot go live');
RESET ROLE;

SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, NULL, 22, NULL)$$, '22023', NULL, 'a check names its lib');
SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, 'lib; drop', 22, NULL)$$, '22023', NULL, 'as a plain version');
SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 9, '2026.11.15-abc1234', 22, NULL)$$, 'P0002', NULL, 'a check needs a pending or live revision');
SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-abc1234', 22, '{"file": "main.luau"}')$$, '23514', NULL, 'problems are a list');

SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-abc1234', 22, pg_temp.problems());
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, '23514', NULL, 'a revision with problems cannot go live');
SELECT is((SELECT problems -> 0 ->> 'line' FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND revision = 1), '3', 'the author reads the problems');
RESET ROLE;

SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-abc1234', 22, '[]');
SELECT is((SELECT problems FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND revision = 1), NULL, 'an empty list is a pass');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, 'a revision that passed goes live');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001'), 'everyone sees a working script');
RESET ROLE;

SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.16-def5678', 23, pg_temp.problems());
SELECT ok((SELECT broken FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), 'a live revision that fails a new lib marks the script broken');
SELECT is((SELECT checked_host FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND revision = 1), 23, 'with the lib it failed');
SELECT is((SELECT requires_host FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND revision = 1), 22, 'but it still needs only the host api it was published against');

SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001'), 'a user cannot see a broken script');
SELECT ok(NOT scripts.can_view(NULL, '10000000-0000-0000-0000-000000000001'), 'nor can a visitor');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001'), 'nor a grantee');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001'), 'nor a tester');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'), 'the author still sees it');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001'), 'and so do moderators');

SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SELECT ok(NOT scripts.can_access('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001'), 'a user cannot run a broken script');
SELECT ok(NOT scripts.can_access('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001'), 'nor can a grantee');
SELECT ok(scripts.can_access('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'), 'the author can');
SELECT ok(scripts.can_access('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001'), 'and so can moderators');
RESET ROLE;

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT pg_temp.upload('10000000-0000-0000-0000-000000000001', 2);
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 2, '2026.11.16-def5678', 23, NULL);
SELECT ok((SELECT broken FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), 'a pending revision that passes does not mend the live one');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 2)$$, 'the fixed revision goes live');
SELECT is((SELECT requires_host FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND revision = 2), 23, 'a revision published against a newer lib needs its host api');
RESET ROLE;
SELECT ok(NOT (SELECT broken FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), 'and the script is no longer broken');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001'), 'so users see it again');

SELECT * FROM finish();
ROLLBACK;
