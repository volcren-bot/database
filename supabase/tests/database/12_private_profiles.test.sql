BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(8);

CREATE FUNCTION pg_temp.signup(p_id uuid, p_name text, p_role profiles.roles DEFAULT 'user') RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_name || '@example.com',
          '{"provider":"discord"}', jsonb_build_object('full_name', p_name));
  UPDATE profiles.profiles SET role = p_role WHERE id = p_id;
END;
$$;

-- A stable script with a live revision; only the published one is visible to everyone
CREATE FUNCTION pg_temp.make_script(p_id uuid, p_author uuid, p_published boolean) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_author, 'role', 'authenticated')::text, true);
  INSERT INTO scripts.scripts (id, title, description, content, published) VALUES (p_id, 'S ' || p_id, 'd', 'c', p_published);
  UPDATE scripts.metadata SET stage = 'stable' WHERE id = p_id;
  UPDATE scripts.protected SET revision = 1, last_revision = 1 WHERE id = p_id;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'Author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'Hidden', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'Viewer');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'Moderator', 'moderator');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', true);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002', false);

SET LOCAL ROLE anon;
SELECT throws_ok('SELECT * FROM profiles.profiles', '42501', NULL, 'anonymous visitors cannot read profiles');
SELECT results_eq(
  $$SELECT script_id, username FROM scripts.get_authors(ARRAY['10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002']::uuid[])$$,
  $$VALUES ('10000000-0000-0000-0000-000000000001'::uuid, 'Author')$$,
  'anonymous visitors see the author of the published script only');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT results_eq('SELECT username FROM profiles.profiles', $$VALUES ('Viewer')$$, 'a user reads only their own profile');
SELECT is_empty(
  $$SELECT * FROM scripts.get_authors(ARRAY['10000000-0000-0000-0000-000000000002']::uuid[])$$,
  'a user does not see the author of a script hidden from them');
SELECT is_empty(
  $$SELECT * FROM scripts.get_authors(ARRAY['00000000-0000-0000-0000-000000000003']::uuid[])$$,
  'a user ID is not a script ID');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT results_eq(
  $$SELECT username FROM scripts.get_authors(ARRAY['10000000-0000-0000-0000-000000000002']::uuid[])$$,
  $$VALUES ('Hidden')$$,
  'an author sees their own name on their hidden script');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM profiles.profiles WHERE id::text LIKE '00000000-0000-0000-0000-00000000000_'), 4, 'a moderator reads every profile');
SELECT is((SELECT avatar FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000001'), '', 'including avatars');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
