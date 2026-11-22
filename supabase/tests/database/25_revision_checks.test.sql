BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(50);

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

CREATE FUNCTION pg_temp.as_service() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
END;
$$;

CREATE FUNCTION pg_temp.upload(p_script uuid, p_revision integer, p_manifest jsonb DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO scripts.versions (id, files, manifest) VALUES (p_script, ARRAY['main.luau'], p_manifest);
  INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', p_script::text || '/' || lpad(p_revision::text, 9, '0') || '/main.luau');
  INSERT INTO scripts.version_keys (id, revision, key) VALUES (p_script, p_revision, decode(repeat('ab', 32), 'hex'));
END;
$$;

CREATE FUNCTION pg_temp.problems() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '[{"file": "main.luau", "line": 3, "column": 14, "message": "Key ''form'' not found in table"}]'::jsonb;
$$;

CREATE FUNCTION pg_temp.pinned(p_revision integer) RETURNS text LANGUAGE sql AS $$
  SELECT injector FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND revision = p_revision;
$$;

CREATE FUNCTION pg_temp.broken() RETURNS boolean LANGUAGE sql AS $$
  SELECT broken FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001';
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'player');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'moderator', 'moderator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'grantee');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000005', 'tester', 'tester');

SELECT scripts.register_injector('2026.11.15-aaaaaaa', 100);
SELECT scripts.register_injector('2026.11.16-bbbbbbb', 200);
SELECT scripts.register_injector('2026.11.17-ccccccc', 300);

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000001', 'Bosses', 'd', 'c', true);
UPDATE scripts.metadata SET stage = 'stable';
INSERT INTO scripts.share_codes (id, script_id, code_hash, created_by, expires_at, redeemed_by, redeemed_at)
VALUES ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', repeat('a', 64), '00000000-0000-0000-0000-000000000001', now() + interval '1 day', '00000000-0000-0000-0000-000000000004', now());
INSERT INTO scripts.grants (script_id, user_id, code_id) VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', '30000000-0000-0000-0000-000000000001');
SELECT pg_temp.upload('10000000-0000-0000-0000-000000000001', 1);

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-aaaaaaa', NULL)$$, '42501', NULL, 'an author cannot record a check');
SELECT throws_ok($$UPDATE scripts.versions SET checked_injector = '2026.11.15-aaaaaaa', checked_at = now() WHERE id = '10000000-0000-0000-0000-000000000001'$$, '42501', NULL, 'nor write the check columns');
SELECT throws_ok($$UPDATE scripts.versions SET injector = '2026.11.15-aaaaaaa' WHERE id = '10000000-0000-0000-0000-000000000001'$$, '42501', NULL, 'nor the pin');
SELECT throws_ok($$SELECT scripts.register_injector('2026.11.18-ddddddd', 400)$$, '42501', NULL, 'nor register an injector');
SELECT throws_ok($$SELECT scripts.retire_injector('2026.11.15-aaaaaaa')$$, '42501', NULL, 'nor retire one');
SELECT is((SELECT count(*) FROM scripts.injectors), 3::bigint, 'but anyone reads which injectors exist');
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, '23514', 'revision 1 of script 10000000-0000-0000-0000-000000000001 has not passed the script check', 'an unchecked revision cannot go live');
RESET ROLE;

SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, NULL, NULL)$$, '22023', NULL, 'a check names its injector');
SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.30-unknown', NULL)$$, '22023', NULL, 'a registered one');
SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 9, '2026.11.15-aaaaaaa', NULL)$$, 'P0002', NULL, 'a check needs a pending or live revision');
SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-aaaaaaa', '{"file": "main.luau"}')$$, '23514', NULL, 'problems are a list');
SELECT throws_ok($$SELECT scripts.register_injector('2026.11.15-aaaaaaa', 101)$$, '23505', NULL, 'a release keeps its build');
SELECT throws_ok($$SELECT scripts.register_injector('not a version', 101)$$, '23514', NULL, 'and its version is plain');
SELECT lives_ok($$SELECT scripts.register_injector('2026.11.15-aaaaaaa', 100)$$, 'registering again is a no-op');

SELECT ok(scripts.valid_manifest('{"auto_forward": false}'), 'a manifest can turn auto_forward off');
SELECT ok(NOT scripts.valid_manifest('{"auto_forward": "no"}'), 'with a boolean only');

SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-aaaaaaa', pg_temp.problems());
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, '23514', NULL, 'a revision with problems cannot go live');
SELECT is((SELECT problems -> 0 ->> 'line' FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND revision = 1), '3', 'the author reads the problems');
RESET ROLE;

SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-aaaaaaa', '[]');
SELECT is((SELECT problems FROM scripts.versions WHERE id = '10000000-0000-0000-0000-000000000001' AND revision = 1), NULL, 'an empty list is a pass');
SELECT is(pg_temp.pinned(1), NULL, 'a pending revision has no pin yet');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, 'a revision that passed goes live');
SELECT is(pg_temp.pinned(1), '2026.11.15-aaaaaaa', 'pinned to the injector it passed');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001'), 'everyone sees a working script');
RESET ROLE;

SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.16-bbbbbbb', pg_temp.problems());
SELECT is(pg_temp.pinned(1), '2026.11.15-aaaaaaa', 'a live revision that fails a newer injector keeps its pin');
SELECT ok(NOT pg_temp.broken(), 'and keeps running');

SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.16-bbbbbbb', NULL);
SELECT is(pg_temp.pinned(1), '2026.11.16-bbbbbbb', 'one that passes moves to the newer injector');
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-aaaaaaa', NULL);
SELECT is(pg_temp.pinned(1), '2026.11.16-bbbbbbb', 'never back to an older one');

SELECT is(scripts.retire_injector('2026.11.16-bbbbbbb'), 1, 'retiring an injector breaks the scripts live on it');
SELECT ok(pg_temp.broken(), 'so the script is broken');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001'), 'a user cannot see a broken script');
SELECT ok(NOT scripts.can_view(NULL, '10000000-0000-0000-0000-000000000001'), 'nor can a visitor');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001'), 'nor a grantee');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001'), 'nor a tester');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'), 'the author still sees it');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001'), 'and so do moderators');

SET LOCAL ROLE service_role;
SELECT pg_temp.as_service();
SELECT ok(NOT scripts.can_access('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001'), 'a user cannot run a broken script');
SELECT ok(scripts.can_access('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'), 'the author can reach it');
SELECT throws_ok($$SELECT * FROM payments.start_session('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001')$$, '55000', NULL, 'but no session starts on a retired injector');
RESET ROLE;

SELECT throws_ok($$SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.16-bbbbbbb', NULL)$$, '22023', NULL, 'nothing is checked against a retired injector');
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.17-ccccccc', NULL);
SELECT is(pg_temp.pinned(1), '2026.11.17-ccccccc', 'a pass on a supported injector moves a broken revision onto it');
SELECT ok(NOT pg_temp.broken(), 'and mends the script');
SET LOCAL ROLE service_role;
SELECT pg_temp.as_service();
SELECT is((SELECT injector FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001')), '2026.11.17-ccccccc', 'a session names the injector to run it with');
RESET ROLE;

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT pg_temp.upload('10000000-0000-0000-0000-000000000001', 2, '{"auto_forward": false}');
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 2, '2026.11.17-ccccccc', NULL);
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 2)$$, 'a revision that keeps its pin goes live');
RESET ROLE;
SELECT scripts.register_injector('2026.11.18-ddddddd', 400);
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 2, '2026.11.18-ddddddd', NULL);
SELECT is(pg_temp.pinned(2), '2026.11.17-ccccccc', 'with auto_forward off a pass on a newer injector leaves the pin');
SELECT scripts.retire_injector('2026.11.17-ccccccc');
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 2, '2026.11.18-ddddddd', NULL);
SELECT ok(pg_temp.broken(), 'even once its injector is retired');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT pg_temp.upload('10000000-0000-0000-0000-000000000001', 3);
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 3, '2026.11.18-ddddddd', NULL);
SELECT ok(pg_temp.broken(), 'a pending revision that passes does not mend the live one');
SELECT scripts.retire_injector('2026.11.18-ddddddd');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 3)$$, '23514', NULL, 'a revision checked against a retired injector cannot go live');
RESET ROLE;
SELECT scripts.register_injector('2026.11.19-eeeeeee', 500);
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 3, '2026.11.19-eeeeeee', NULL);
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 3)$$, 'checked again it goes live');
RESET ROLE;
SELECT ok(NOT pg_temp.broken(), 'and the script is no longer broken');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001'), 'so users see it again');

SELECT * FROM finish();
ROLLBACK;
