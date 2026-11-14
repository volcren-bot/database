BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(29);

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

CREATE FUNCTION pg_temp.publish(p_script uuid, p_revision integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', p_script::text || '/' || lpad(p_revision::text, 9, '0') || '/main.luau');
  PERFORM scripts.set_version_key(p_script, p_revision, repeat('ab', 32));
  PERFORM scripts.publish_version(p_script, p_revision);
END;
$$;

CREATE FUNCTION pg_temp.valid(p_manifest text) RETURNS boolean LANGUAGE sql AS $$
  SELECT scripts.valid_manifest(p_manifest::jsonb);
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'player');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000001', 'Bosses', 'd', 'c', true);
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000002', 'Hidden', 'd', 'c', false);
UPDATE scripts.metadata SET stage = 'stable';

SELECT ok(scripts.valid_manifest(NULL), 'no manifest is valid');
SELECT ok(pg_temp.valid('{"queueable": true, "goals": [{"id": "kills", "label": "Kills"}], "settings": {"fields": [{"id": "food", "kind": "text"}]}}'), 'a full manifest is valid');
SELECT ok(pg_temp.valid('{}'), 'an empty manifest is valid');
SELECT ok(NOT pg_temp.valid('[]'), 'a manifest is an object');
SELECT ok(NOT pg_temp.valid('{"queuable": true}'), 'unknown keys are refused, so a misspelling is not silently false');
SELECT ok(NOT pg_temp.valid('{"queueable": "yes"}'), 'queueable is a boolean');
SELECT ok(pg_temp.valid('{"finish_grace_minutes": 120}'), 'a grace period of up to 120 minutes is valid');
SELECT ok(NOT pg_temp.valid('{"finish_grace_minutes": 0}'), 'a grace period is at least a minute');
SELECT ok(NOT pg_temp.valid('{"finish_grace_minutes": 2.5}'), 'and whole minutes');
SELECT ok(NOT pg_temp.valid('{"goals": {"id": "kills"}}'), 'goals is an array');
SELECT ok(NOT pg_temp.valid('{"goals": [{"id": "kills", "label": "Kills", "max": 5}]}'), 'a goal has only an id and a label');
SELECT ok(NOT pg_temp.valid('{"goals": [{"id": "Kills!", "label": "Kills"}]}'), 'a goal id is lowercase snake case');
SELECT ok(NOT pg_temp.valid('{"goals": [{"id": "kills", "label": ""}]}'), 'a goal label is not empty');
SELECT ok(NOT pg_temp.valid('{"goals": [{"id": "kills", "label": "A"}, {"id": "kills", "label": "B"}]}'), 'goal ids are unique');
SELECT ok(NOT pg_temp.valid((SELECT jsonb_build_object('goals', jsonb_agg(jsonb_build_object('id', 'g' || i, 'label', 'G'))) FROM generate_series(1, 17) i)::text), 'at most 16 goals');
SELECT ok(NOT pg_temp.valid('{"settings": {"title": "x"}}'), 'settings need a fields array');
SELECT ok(NOT pg_temp.valid('{"settings": {"fields": ["food"]}}'), 'each field is an object');
SELECT ok(NOT pg_temp.valid(jsonb_build_object('settings', jsonb_build_object('fields', jsonb_build_array(jsonb_build_object('text', repeat('x', 70000)))))::text), 'a manifest is at most 64 KiB');

SET LOCAL ROLE authenticated;
SELECT throws_ok($$INSERT INTO scripts.versions (id, files, manifest) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau'], '{"queuable": true}')$$,
  '23514', NULL, 'an invalid manifest is refused on insert');
SELECT lives_ok($$INSERT INTO scripts.versions (id, files, manifest) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau'], '{"queueable": true, "goals": [{"id": "kills", "label": "Kills"}], "settings": {"fields": []}}')$$,
  'the author inserts a revision with its manifest');
SELECT throws_ok($$UPDATE scripts.versions SET manifest = '{"queueable": false}' WHERE id = '10000000-0000-0000-0000-000000000001'$$,
  '42501', NULL, 'a manifest cannot change after insert');
SELECT is((SELECT queueable FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), false, 'a pending revision does not make the script queueable');
SELECT pg_temp.publish('10000000-0000-0000-0000-000000000001', 1);
SELECT is((SELECT queueable FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), true, 'publishing copies queueable from the manifest');

INSERT INTO scripts.versions (id, files, manifest) VALUES ('10000000-0000-0000-0000-000000000002', ARRAY['main.luau'], '{"queueable": true}');
SELECT pg_temp.publish('10000000-0000-0000-0000-000000000002', 1);

SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SELECT is((SELECT row(revision, manifest -> 'goals' -> 0 ->> 'id')::text FROM scripts.live_manifest('10000000-0000-0000-0000-000000000001')), '(1,kills)',
  'a player who sees the script reads the live manifest');
SELECT is((SELECT count(*)::int FROM scripts.live_manifest('10000000-0000-0000-0000-000000000002')), 0, 'but not the manifest of a script hidden from them');
RESET ROLE;

SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT * FROM scripts.live_manifest('10000000-0000-0000-0000-000000000001')$$, '42501', NULL, 'anonymous callers cannot read manifests');
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau']);
SELECT pg_temp.publish('10000000-0000-0000-0000-000000000001', 2);
SELECT is((SELECT queueable FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), false, 'a later revision without a manifest is not queueable');
SELECT is((SELECT row(revision, manifest)::text FROM scripts.live_manifest('10000000-0000-0000-0000-000000000001')), '(2,)', 'and its live manifest is null');
RESET ROLE;

SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SELECT is((SELECT count(*)::int FROM scripts.live_manifest('10000000-0000-0000-0000-000000000002')), 1, 'service_role reads any live manifest');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
