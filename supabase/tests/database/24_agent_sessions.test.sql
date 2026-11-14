BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(27);

CREATE FUNCTION pg_temp.signup(p_id uuid, p_name text, p_role profiles.roles DEFAULT 'user') RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_name || '@example.com',
          '{"provider":"discord"}', jsonb_build_object('full_name', p_name));
  UPDATE profiles.profiles SET role = p_role WHERE id = p_id;
END;
$$;

CREATE FUNCTION pg_temp.age(p_session uuid, p_by interval) RETURNS void LANGUAGE sql AS $$
  UPDATE payments.agent_sessions SET started_at = started_at - p_by, last_seen = last_seen - p_by WHERE id = p_session;
$$;

CREATE FUNCTION pg_temp.active(p_session uuid) RETURNS integer LANGUAGE sql AS $$
  SELECT active_seconds FROM payments.agent_sessions WHERE id = p_session;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'agent');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'stranger');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'banned');
UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000003';

CREATE TEMP TABLE s (name text PRIMARY KEY, id uuid);

INSERT INTO s VALUES ('a', payments.start_agent_session('00000000-0000-0000-0000-000000000001'));
SELECT isnt((SELECT id FROM s WHERE name = 'a'), NULL, 'start_agent_session returns the new session');
SELECT is((SELECT user_id FROM payments.agent_sessions WHERE id = (SELECT id FROM s WHERE name = 'a')), '00000000-0000-0000-0000-000000000001'::uuid, 'owned by the caller');
SELECT is(pg_temp.active((SELECT id FROM s WHERE name = 'a')), 0, 'with no active time yet');
SELECT is((SELECT count(*)::int FROM payments.credits_ledger WHERE user_id = '00000000-0000-0000-0000-000000000001'), 0, 'and nothing is billed');
SELECT throws_ok($$SELECT payments.start_agent_session('00000000-0000-0000-0000-000000000003')$$, '42501', 'account banned', 'a banned account cannot start one');

SELECT pg_temp.age((SELECT id FROM s WHERE name = 'a'), interval '50 seconds');
SELECT is(payments.heartbeat_agent_session('00000000-0000-0000-0000-000000000001', (SELECT id FROM s WHERE name = 'a'), 120), true, 'a heartbeat keeps the session open');
SELECT is(pg_temp.active((SELECT id FROM s WHERE name = 'a')), 50, 'and adds the time since the previous beat');

SELECT pg_temp.age((SELECT id FROM s WHERE name = 'a'), interval '10 minutes');
SELECT is(payments.heartbeat_agent_session('00000000-0000-0000-0000-000000000001', (SELECT id FROM s WHERE name = 'a'), 120), true, 'a late heartbeat before the sweep still counts');
SELECT is(pg_temp.active((SELECT id FROM s WHERE name = 'a')), 170, 'but a long gap adds only the cap');

SELECT throws_ok($$SELECT payments.heartbeat_agent_session('00000000-0000-0000-0000-000000000002', (SELECT id FROM s WHERE name = 'a'), 120)$$, 'P0002', 'agent session not found', 'another account cannot heartbeat the session');
SELECT throws_ok($$SELECT payments.heartbeat_agent_session('00000000-0000-0000-0000-000000000001', gen_random_uuid(), 120)$$, 'P0002', 'agent session not found', 'an unknown session looks the same');
SELECT throws_ok($$SELECT payments.end_agent_session('00000000-0000-0000-0000-000000000002', (SELECT id FROM s WHERE name = 'a'), 120)$$, 'P0002', 'agent session not found', 'another account cannot end the session');

SELECT pg_temp.age((SELECT id FROM s WHERE name = 'a'), interval '30 seconds');
SELECT is(payments.end_agent_session('00000000-0000-0000-0000-000000000001', (SELECT id FROM s WHERE name = 'a'), 120), true, 'the owner ends the session');
SELECT is(pg_temp.active((SELECT id FROM s WHERE name = 'a')), 200, 'counting the time since the last beat');
SELECT is((SELECT end_reason::text FROM payments.agent_sessions WHERE id = (SELECT id FROM s WHERE name = 'a')), 'stopped', 'with reason stopped');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'a'), interval '30 seconds');
SELECT is(payments.end_agent_session('00000000-0000-0000-0000-000000000001', (SELECT id FROM s WHERE name = 'a'), 120), false, 'ending again is a no-op');
SELECT is(payments.heartbeat_agent_session('00000000-0000-0000-0000-000000000001', (SELECT id FROM s WHERE name = 'a'), 120), false, 'a heartbeat on an ended session says it ended');
SELECT is(pg_temp.active((SELECT id FROM s WHERE name = 'a')), 200, 'and neither adds time');

UPDATE payments.config SET max_agent_sessions = 2;
INSERT INTO s VALUES ('b', payments.start_agent_session('00000000-0000-0000-0000-000000000001'));
INSERT INTO s VALUES ('c', payments.start_agent_session('00000000-0000-0000-0000-000000000001'));
SELECT throws_ok($$SELECT payments.start_agent_session('00000000-0000-0000-0000-000000000001')$$, '54000', 'too many agent sessions', 'an account is capped at max_agent_sessions open sessions');
SELECT lives_ok($$SELECT payments.start_agent_session('00000000-0000-0000-0000-000000000002')$$, 'the cap is per account');

SELECT pg_temp.age((SELECT id FROM s WHERE name = 'b'), interval '6 minutes');
SELECT is(payments.end_stale_sessions(), 1, 'the stale session sweep ends an agent session without heartbeats');
SELECT is((SELECT end_reason::text FROM payments.agent_sessions WHERE id = (SELECT id FROM s WHERE name = 'b')), 'timeout', 'with reason timeout');
SELECT is((SELECT ended_at FROM payments.agent_sessions WHERE id = (SELECT id FROM s WHERE name = 'c')), NULL, 'and leaves a live one open');
SELECT lives_ok($$SELECT payments.start_agent_session('00000000-0000-0000-0000-000000000001')$$, 'an ended session frees its place under the cap');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SELECT throws_ok($$SELECT payments.start_agent_session('00000000-0000-0000-0000-000000000001')$$, '42501', NULL, 'authenticated cannot call start_agent_session');
SELECT throws_ok($$SELECT payments.heartbeat_agent_session('00000000-0000-0000-0000-000000000001', gen_random_uuid(), 120)$$, '42501', NULL, 'authenticated cannot call heartbeat_agent_session');
SELECT throws_ok($$SELECT payments.end_agent_session('00000000-0000-0000-0000-000000000001', gen_random_uuid(), 120)$$, '42501', NULL, 'authenticated cannot call end_agent_session');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
