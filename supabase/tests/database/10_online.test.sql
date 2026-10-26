BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(4);

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

-- An open session of p_user on p_script, last heard from p_ago ago
CREATE FUNCTION pg_temp.session(p_user uuid, p_script uuid, p_ago interval DEFAULT '0') RETURNS void LANGUAGE sql AS $$
  INSERT INTO payments.sessions (user_id, script_id, author_id, revision, price, last_seen)
  VALUES (p_user, p_script, '00000000-0000-0000-0000-000000000001', 1, 0, now() - p_ago);
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'viewer');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', true);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', false);

SELECT pg_temp.session('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.session('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.session('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', interval '1 day');
SELECT pg_temp.session('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002');
SELECT pg_temp.session('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002');

SET LOCAL ROLE anon;
SELECT results_eq('SELECT script_id, users FROM stats.online_per_script()',
  $$VALUES ('10000000-0000-0000-0000-000000000001'::uuid, 2::bigint)$$,
  'anonymous visitors only see the published script, without timed-out sessions');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT results_eq('SELECT script_id, users FROM stats.online_per_script()',
  $$VALUES ('10000000-0000-0000-0000-000000000001'::uuid, 2::bigint)$$,
  'other users do not see the hidden script either');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT results_eq('SELECT script_id, users FROM stats.online_per_script() ORDER BY script_id',
  $$VALUES ('10000000-0000-0000-0000-000000000001'::uuid, 2::bigint), ('10000000-0000-0000-0000-000000000002'::uuid, 1::bigint)$$,
  'the author sees their hidden script too, counting a user with two sessions once');
SELECT is(stats.online_count(), 2::bigint, 'online_count counts distinct users across scripts');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
