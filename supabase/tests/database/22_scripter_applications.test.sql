BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(21);

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

CREATE FUNCTION pg_temp.service() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

CREATE FUNCTION pg_temp.make_script(p_id uuid, p_author uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.act(p_author);
  INSERT INTO scripts.scripts (id, title, description, content, published) VALUES (p_id, 'S ' || p_id, 'd', 'c', true);
  PERFORM pg_temp.service();
END;
$$;

CREATE FUNCTION pg_temp.ran(p_script uuid, p_user uuid, p_minutes integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payments.sessions (user_id, script_id, author_id, revision, price, charged_minutes, ended_at, end_reason)
  VALUES (p_user, p_script, '00000000-0000-0000-0000-000000000001', 1, 0, p_minutes, now(), 'stopped');
END;
$$;

CREATE FUNCTION pg_temp.users(p_script uuid) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  v integer;
BEGIN
  PERFORM pg_temp.act('00000000-0000-0000-0000-000000000001');
  SET LOCAL ROLE authenticated;
  SELECT g.users INTO v FROM profiles.scripter_progress('00000000-0000-0000-0000-000000000001') g WHERE g.script_id = p_script;
  PERFORM pg_temp.service();
  RETURN v;
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'admin', 'administrator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'mod', 'moderator');
SELECT pg_temp.signup(('00000000-0000-0000-0000-0000000000' || n)::uuid, 'runner' || n) FROM generate_series(10, 15) n;

SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001');

SELECT is((SELECT role FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000001'), 'contributor', 'the author is a contributor');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000010');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT profiles.apply_for_scripter('hi')$$, '42501', NULL, 'a user without scripts cannot apply');
SELECT throws_ok($$SELECT * FROM profiles.scripter_progress('00000000-0000-0000-0000-000000000001')$$, '42501', NULL, 'nor read another user''s progress');
SELECT pg_temp.service();

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::integer FROM profiles.scripter_progress('00000000-0000-0000-0000-000000000001')), 3, 'progress lists every script');
SELECT throws_ok($$SELECT profiles.apply_for_scripter('hi')$$, '23514', NULL, 'scripts nobody ran do not qualify');
SELECT pg_temp.service();

SELECT pg_temp.ran('10000000-0000-0000-0000-000000000001', ('00000000-0000-0000-0000-0000000000' || n)::uuid, 10) FROM generate_series(10, 14) n;
SELECT pg_temp.ran('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010', 30);
SELECT pg_temp.ran('10000000-0000-0000-0000-000000000002', ('00000000-0000-0000-0000-0000000000' || n)::uuid, 10) FROM generate_series(10, 13) n;
SELECT pg_temp.ran('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 60);
SELECT pg_temp.ran('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000015', 9);
SELECT pg_temp.ran('10000000-0000-0000-0000-000000000003', ('00000000-0000-0000-0000-0000000000' || n)::uuid, 10) FROM generate_series(11, 15) n;

SELECT is(pg_temp.users('10000000-0000-0000-0000-000000000001'), 5, 'a user counts once however often they ran it');
SELECT is(pg_temp.users('10000000-0000-0000-0000-000000000002'), 4, 'the author and short sessions do not count');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT profiles.apply_for_scripter('hi')$$, '23514', NULL, 'two qualifying scripts are not enough');
SELECT pg_temp.service();

UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000011';
SELECT is(pg_temp.users('10000000-0000-0000-0000-000000000003'), 4, 'banned users do not count');
UPDATE profiles.profiles SET banned_at = NULL WHERE id = '00000000-0000-0000-0000-000000000011';

SELECT pg_temp.ran('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000015', 10);

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT profiles.apply_for_scripter('  I write scripts  ')$$, 'three scripts with five users each can apply');
SELECT throws_ok($$SELECT profiles.apply_for_scripter('again')$$, '23505', NULL, 'only one pending application at a time');
SELECT is((SELECT message FROM profiles.scripter_applications), 'I write scripts', 'the applicant reads their trimmed application');
SELECT throws_ok($$INSERT INTO profiles.scripter_applications (user_id, message) VALUES ('00000000-0000-0000-0000-000000000001', 'x')$$,
  '42501', NULL, 'clients cannot insert applications directly');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000010');
SELECT is((SELECT count(*)::integer FROM profiles.scripter_applications), 0, 'others cannot read it');
SELECT pg_temp.service();

SELECT throws_ok($$SELECT profiles.decide_scripter_application('00000000-0000-0000-0000-000000000003', (SELECT id FROM profiles.scripter_applications), true, NULL)$$,
  '42501', NULL, 'only administrators decide');
SELECT throws_ok($$SELECT profiles.decide_scripter_application('00000000-0000-0000-0000-000000000002', (SELECT id FROM profiles.scripter_applications), false, ' ')$$,
  'P0001', 'a reason is required to reject', 'a rejection needs a reason');
SELECT profiles.decide_scripter_application('00000000-0000-0000-0000-000000000002', (SELECT id FROM profiles.scripter_applications), false, 'not yet');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT profiles.apply_for_scripter('please')$$, '55000', NULL, 'a rejected contributor waits before applying again');
SELECT pg_temp.service();

UPDATE profiles.scripter_applications SET decided_at = now() - interval '31 days';

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT profiles.apply_for_scripter('please')$$, 'and can apply once the wait is over');
SELECT pg_temp.service();

SELECT profiles.decide_scripter_application('00000000-0000-0000-0000-000000000002',
  (SELECT id FROM profiles.scripter_applications WHERE status = 'pending'), true, NULL);

SELECT is((SELECT role FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000001'), 'scripter', 'approval promotes to scripter');
SELECT is((SELECT count(*)::integer FROM scripts.scripts WHERE published), 0, 'promotion unpublishes the community scripts');
SELECT throws_ok($$SELECT profiles.decide_scripter_application('00000000-0000-0000-0000-000000000002', (SELECT max(id) FROM profiles.scripter_applications), true, NULL)$$,
  'P0002', NULL, 'a decided application cannot be decided again');

SELECT * FROM finish();
ROLLBACK;
