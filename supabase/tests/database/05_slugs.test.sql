BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(15);

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

CREATE FUNCTION pg_temp.url_of(p_id uuid) RETURNS text LANGUAGE sql AS $$ SELECT url FROM scripts.scripts WHERE id = p_id $$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'other', 'scripter');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000001', 'Auto Fighter', 'd', 'c');
SELECT is(pg_temp.url_of('10000000-0000-0000-0000-000000000001'), 'auto-fighter', 'a free slug has no suffix');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('20000000-0000-0000-0000-000000000002', 'Auto  Fighter!', 'd', 'c');
SELECT is(pg_temp.url_of('20000000-0000-0000-0000-000000000002'), 'auto-fighter-20000000', 'a colliding slug gets the id suffix');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
UPDATE scripts.scripts SET description = 'new' WHERE id = '10000000-0000-0000-0000-000000000001';
SELECT is(pg_temp.url_of('10000000-0000-0000-0000-000000000001'), 'auto-fighter', 'editing something other than the title keeps the slug');

UPDATE scripts.scripts SET title = 'Auto Fighter Pro' WHERE id = '10000000-0000-0000-0000-000000000001';
SELECT is(pg_temp.url_of('10000000-0000-0000-0000-000000000001'), 'auto-fighter-pro', 'the slug follows a rename');
SELECT is((SELECT id FROM scripts.slugs WHERE slug = 'auto-fighter'), '10000000-0000-0000-0000-000000000001'::uuid, 'the old slug still points at the script');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('30000000-0000-0000-0000-000000000003', 'Auto Fighter', 'd', 'c');
SELECT is(pg_temp.url_of('30000000-0000-0000-0000-000000000003'), 'auto-fighter-30000000', 'a freed slug is not given to another script');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
UPDATE scripts.scripts SET title = 'Auto Fighter' WHERE id = '10000000-0000-0000-0000-000000000001';
SELECT is(pg_temp.url_of('10000000-0000-0000-0000-000000000001'), 'auto-fighter', 'renaming back reuses the original slug');
SELECT is((SELECT count(*)::int FROM scripts.slugs WHERE id = '10000000-0000-0000-0000-000000000001'), 2, 'and it is not recorded twice');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('60000000-0000-0000-0000-000000000006', 'Auto Fighter Pro', 'd', 'c');
SELECT is(pg_temp.url_of('60000000-0000-0000-0000-000000000006'), 'auto-fighter-pro-60000000', 'a slug left by a rename is not given to another script');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');

INSERT INTO scripts.scripts (id, title, description, content) VALUES ('40000000-0000-0000-0000-000000000004', 'New', 'd', 'c');
SELECT is(pg_temp.url_of('40000000-0000-0000-0000-000000000004'), 'new-40000000', 'a title that matches the create route gets the suffix');

INSERT INTO scripts.scripts (id, title, description, content) VALUES ('50000000-0000-0000-0000-000000000005', '!!!', 'd', 'c');
SELECT is(pg_temp.url_of('50000000-0000-0000-0000-000000000005'), 'script', 'a title with no usable characters falls back to "script"');

-- access -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT throws_ok($$UPDATE scripts.scripts SET url = 'hijack' WHERE id = '10000000-0000-0000-0000-000000000001'$$, '42501', NULL, 'authors cannot write the url directly');
SELECT throws_ok($$INSERT INTO scripts.slugs (slug, id) VALUES ('hijack', '10000000-0000-0000-0000-000000000001')$$, '42501', NULL, 'clients cannot write slugs');
SELECT is((SELECT count(*)::int FROM scripts.slugs WHERE id = '10000000-0000-0000-0000-000000000001'), 2, 'an author sees the slugs of their own script');

SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SELECT is((SELECT count(*)::int FROM scripts.slugs), 0, 'anonymous visitors see no slugs of unpublished scripts');

SELECT * FROM finish();
ROLLBACK;
