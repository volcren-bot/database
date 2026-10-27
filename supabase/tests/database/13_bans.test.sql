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

-- A stable, published script with a live revision (written as postgres with the author's claims)
CREATE FUNCTION pg_temp.make_script(p_id uuid, p_author uuid, p_price bigint) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_author, 'role', 'authenticated')::text, true);
  INSERT INTO scripts.scripts (id, title, description, content, published) VALUES (p_id, 'S ' || p_id, 'd', 'c', true);
  UPDATE scripts.metadata SET stage = 'stable', type = CASE WHEN p_price > 0 THEN 'premium'::scripts.type ELSE 'free'::scripts.type END, price = p_price WHERE id = p_id;
  INSERT INTO scripts.versions (id, files) VALUES (p_id, ARRAY['main.luau']);
  INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', p_id || '/000000001/main.luau');
  INSERT INTO scripts.version_keys (id, revision, key) VALUES (p_id, 1, decode(repeat('ab', 32), 'hex'));
  SET LOCAL ROLE authenticated;
  PERFORM scripts.publish_version(p_id, 1);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'admin', 'administrator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'admin2', 'administrator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'mod', 'moderator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'user');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000005', 'author', 'scripter');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000005', 10);
SELECT payments.post_credits('00000000-0000-0000-0000-000000000004', 'adjustment', 1000);

-- who can ban whom ---------------------------------------------------------------------
SELECT throws_ok($$SELECT profiles.set_banned('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000004', true, 'spam')$$,
  '42501', 'only administrators can ban', 'a moderator cannot ban');
SELECT throws_ok($$SELECT profiles.set_banned(NULL, '00000000-0000-0000-0000-000000000004', true, 'spam')$$,
  '42501', 'only administrators can ban', 'a ban needs an administrator');
SELECT throws_ok($$SELECT profiles.set_banned('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', true, 'spam')$$,
  '42501', 'administrators cannot be banned', 'an administrator cannot ban another administrator');
SELECT throws_ok($$SELECT profiles.set_banned('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000009', true, 'spam')$$,
  'P0002', NULL, 'an unknown user cannot be banned');
SELECT throws_ok($$SELECT profiles.set_banned('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', true, '  ')$$,
  'P0001', 'a reason is required', 'a ban needs a reason');
SELECT is((SELECT count(*)::int FROM profiles.bans), 0, 'refused bans are not recorded');

-- a ban ends running scripts ----------------------------------------------------------
CREATE TEMP TABLE s (id uuid, revision int, files text[], entry text);
INSERT INTO s SELECT * FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
UPDATE payments.sessions SET started_at = started_at - interval '3 minutes', charged_until = charged_until - interval '3 minutes';

SELECT is(profiles.set_banned('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', true, ' spam '), true,
  'an administrator can ban a user');
SELECT ok((SELECT banned_at IS NOT NULL FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000004'), 'the profile is marked banned');
SELECT ok(profiles.is_banned('00000000-0000-0000-0000-000000000004'), 'is_banned says so');
SELECT results_eq(
  $$SELECT admin_id, user_id, banned, reason FROM profiles.bans ORDER BY id$$,
  $$VALUES ('00000000-0000-0000-0000-000000000001'::uuid, '00000000-0000-0000-0000-000000000004'::uuid, true, 'spam')$$,
  'the ban is recorded with the administrator and the trimmed reason');
SELECT is((SELECT end_reason FROM payments.sessions WHERE id = (SELECT id FROM s)), 'stopped'::payments.session_end, 'the user''s running session is ended');
SELECT is((SELECT credits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000004'), 970::bigint, 'and charged for the minutes it ran');
SELECT is(profiles.set_banned('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', true, 'again'), false,
  'banning a banned user changes nothing');
SELECT is((SELECT count(*)::int FROM profiles.bans), 1, 'and records nothing');

-- what a banned user can't do --------------------------------------------------------
SELECT throws_ok($$SELECT payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001')$$,
  '42501', 'account banned', 'a banned user cannot start a session');

SELECT is(profiles.set_banned('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000005', true, 'malware'), true,
  'a scripter can be banned');
INSERT INTO scripts.deploy_tokens (script_id, name, token_hash, created_by)
VALUES ('10000000-0000-0000-0000-000000000001', 'ci', repeat('a', 64), '00000000-0000-0000-0000-000000000005');
SELECT throws_ok($$SELECT scripts.use_deploy_token('10000000-0000-0000-0000-000000000001', repeat('a', 64))$$,
  '42501', 'invalid deploy token', 'a banned scripter''s deploy tokens stop working');

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau']);
INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000002/main.luau');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 2)$$,
  '42501', 'not allowed', 'a banned scripter cannot publish a revision');
RESET ROLE;
SELECT is((SELECT revision FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), 1, 'the live revision is unchanged');

-- unbanning ----------------------------------------------------------------------------
SELECT is(profiles.set_banned('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000005', false, 'false positive'), true,
  'any administrator can lift a ban');
SELECT ok(NOT profiles.is_banned('00000000-0000-0000-0000-000000000005'), 'the user is no longer banned');
SELECT lives_ok($$SELECT scripts.use_deploy_token('10000000-0000-0000-0000-000000000001', repeat('a', 64))$$,
  'their deploy tokens work again');
SELECT is(profiles.set_banned('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000005', false, 'again'), false,
  'unbanning a user who is not banned changes nothing');
SELECT is((SELECT count(*)::int FROM profiles.bans WHERE NOT banned), 1, 'the unban is recorded once');

-- the record is append-only and private -------------------------------------------------
SELECT throws_like($$DELETE FROM profiles.bans$$, '%append-only%', 'ban records cannot be deleted');
SELECT throws_like($$UPDATE profiles.bans SET reason = 'x'$$, '%append-only%', 'or changed');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM profiles.bans$$, '42501', NULL, 'clients cannot read the ban record, not even administrators');
SELECT throws_ok($$SELECT profiles.set_banned('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', false, 'x')$$,
  '42501', NULL, 'clients cannot ban or unban');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
SELECT throws_ok($$UPDATE profiles.profiles SET banned_at = NULL WHERE id = '00000000-0000-0000-0000-000000000004'$$,
  '42501', NULL, 'a banned user cannot unban themselves');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
