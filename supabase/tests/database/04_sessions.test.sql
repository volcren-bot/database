BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(42);

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
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_author, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM scripts.publish_version(p_id, 1);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

-- Moves a session back in time as if p_by had passed
CREATE FUNCTION pg_temp.age(p_session uuid, p_by interval) RETURNS void LANGUAGE sql AS $$
  UPDATE payments.sessions SET started_at = started_at - p_by, charged_until = charged_until - p_by, last_seen = last_seen - p_by WHERE id = p_session;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'payer');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'tester', 'tester');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'broke');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 10);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 0);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', 1);
SELECT payments.post_credits('00000000-0000-0000-0000-000000000002', 'adjustment', 1000);
SELECT payments.post_credits('00000000-0000-0000-0000-000000000004', 'adjustment', 9);

CREATE TEMP TABLE s (name text PRIMARY KEY, id uuid, revision int, files text[]);

-- starting -------------------------------------------------------------------
INSERT INTO s SELECT 'a', * FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
SELECT is((SELECT revision FROM s WHERE name = 'a'), 1, 'start_session returns the live revision');
SELECT is((SELECT files FROM s WHERE name = 'a'), ARRAY['main.luau'], 'and its files');
SELECT is((SELECT price FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'a')), 10::bigint, 'the session stores the price');
SELECT is(stats.online_count(), 1::bigint, 'an open session counts as online');
SELECT throws_ok($$SELECT payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001')$$, '42501', 'script not accessible', 'a balance below one minute cannot start a session');

-- a price change during a session does not change what that session pays --------------
UPDATE scripts.metadata SET price = 100 WHERE id = '10000000-0000-0000-0000-000000000001';
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'a'), interval '5 minutes');
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 'a')), true, 'a heartbeat charges the elapsed minutes and keeps the session running');
SELECT is((SELECT credits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000002'), 950::bigint, 'the session pays its own price (5 x 10), not the new one');

UPDATE scripts.metadata SET price = 10 WHERE id = '10000000-0000-0000-0000-000000000001';

-- 10 minutes charged by heartbeats + the remaining 2 minutes at the end ------------------------
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'a'), interval '5 minutes');
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 'a')), true, 'the second heartbeat');
SELECT is((SELECT count(*)::int FROM payments.credits_ledger WHERE kind = 'usage' AND session_id = (SELECT id FROM s WHERE name = 'a')), 2, 'two heartbeats are charged');
SELECT is((SELECT sum(minutes)::int FROM payments.credits_ledger WHERE kind = 'usage' AND session_id = (SELECT id FROM s WHERE name = 'a')), 10, 'covering 10 minutes');
UPDATE payments.sessions SET last_seen = charged_until + interval '2 minutes' WHERE id = (SELECT id FROM s WHERE name = 'a');
SELECT is(payments.end_session((SELECT id FROM s WHERE name = 'a'), 'stopped'), 20::bigint, 'end_session charges the remaining 2 minutes');
SELECT is((SELECT credits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000002'), 880::bigint, '12 minutes cost 120 credits');
SELECT is((SELECT earnings FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000001'), 96::bigint, 'the author gets 80% of it');
SELECT is(payments.end_session((SELECT id FROM s WHERE name = 'a'), 'stopped'), 0::bigint, 'end_session is idempotent');
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 'a')), false, 'a heartbeat on an ended session says stop');
SELECT is(stats.online_count(), 0::bigint, 'an ended session is not online');

-- 1 credit/minute with the 20% fee pays the author 4 credits per 5 minutes ----------
INSERT INTO s SELECT 'b', * FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'b'), interval '5 minutes');
SELECT payments.heartbeat_session((SELECT id FROM s WHERE name = 'b'));
SELECT is((SELECT amount FROM payments.earnings_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'b')), 4::bigint, 'the author earns 4 credits per 5 minutes at 1 credit/minute');
SELECT is((SELECT amount FROM payments.credits_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'b')), -5::bigint, 'the user pays 5');
SELECT payments.end_session((SELECT id FROM s WHERE name = 'b'), 'stopped');

-- a run that ends within its first minute still costs a started minute ----------------
INSERT INTO s SELECT 'c', * FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003');
SELECT is(payments.end_session((SELECT id FROM s WHERE name = 'c'), 'stopped'), 1::bigint, 'a run shorter than a minute is billed one minute');

-- stops at a zero balance, the shortfall goes to unpaid ---------------------------------
INSERT INTO s SELECT 'd', * FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
SELECT payments.post_credits('00000000-0000-0000-0000-000000000002', 'adjustment', -((SELECT credits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000002') - 300));
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'd'), interval '5 minutes');
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 'd')), true, 'a charge the balance covers keeps the session running');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'd'), interval '5 minutes');
SELECT payments.post_credits('00000000-0000-0000-0000-000000000002', 'adjustment', -((SELECT credits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000002') - 40));
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 'd')), false, 'the session is stopped when the balance cannot cover the next minute');
SELECT is((SELECT end_reason::text FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'd')), 'insufficient_credits', 'with the matching reason');
SELECT is((SELECT credits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000002'), 0::bigint, 'charging stops at a zero balance');
SELECT is((SELECT unpaid FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'd')), 10::bigint, 'and the shortfall is recorded in unpaid');

-- free sessions
INSERT INTO s SELECT 'e', * FROM payments.start_session('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
SELECT is((SELECT price FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'e')), 0::bigint, 'a tester runs premium scripts for free');
INSERT INTO s SELECT 'f', * FROM payments.start_session('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
INSERT INTO s SELECT 'g', * FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'g'), interval '20 minutes');
SELECT payments.heartbeat_session((SELECT id FROM s WHERE name = 'g'));
SELECT payments.end_session(id, 'stopped') FROM s WHERE name IN ('e', 'f', 'g');
SELECT is((SELECT count(*)::int FROM payments.credits_ledger WHERE session_id IN (SELECT id FROM s WHERE name IN ('e', 'f', 'g'))) + (SELECT count(*)::int FROM payments.earnings_ledger WHERE session_id IN (SELECT id FROM s WHERE name IN ('e', 'f', 'g'))), 0, 'free, author and tester sessions write no ledger rows');

-- cron: a stale session times out
INSERT INTO s SELECT 'i', * FROM payments.start_session('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'i'), interval '6 minutes');
SELECT is(payments.end_stale_sessions(), 1, 'a stale session is ended by the cron function');
SELECT is((SELECT end_reason::text FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'i')), 'timeout', 'with reason timeout');

-- usage is charged every minute ------------------------------------------------------
SELECT payments.post_credits('00000000-0000-0000-0000-000000000002', 'adjustment', 1000);
INSERT INTO s SELECT 'h', * FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'h'), interval '1 minute');
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 'h')), true, 'a heartbeat one minute in keeps the session running');
SELECT is((SELECT credits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000002'), 990::bigint, 'and charges that minute');

-- the UI check and the session start agree on the minimum balance -------------------
SELECT is(scripts.can_access('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001'), false, 'below one minute of credits a premium script is not accessible');
SELECT payments.post_credits('00000000-0000-0000-0000-000000000004', 'adjustment', 1);
SELECT is(scripts.can_access('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001'), true, 'with one minute of credits it is');
SELECT lives_ok($$SELECT payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001')$$, 'and a session starts');

-- a deleted account does not block the cron run --------------------------------------
INSERT INTO s SELECT 'k', * FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003');
INSERT INTO s SELECT 'l', * FROM payments.start_session('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003');
SELECT pg_temp.age((SELECT id FROM s WHERE name IN ('k')), interval '6 minutes');
SELECT pg_temp.age((SELECT id FROM s WHERE name IN ('l')), interval '6 minutes');
DELETE FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000002';
SELECT is(payments.end_stale_sessions(), 2, 'a stale session of a deleted user does not stop the others from ending');
SELECT is((SELECT unpaid FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'k')), 1::bigint, 'and its cost is recorded as unpaid');

-- a deleted author: the user is still charged, nobody is paid ---------------------------
INSERT INTO s SELECT 'm', * FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000003');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'm'), interval '6 minutes');
UPDATE payments.accounts SET earnings = 0 WHERE user_id = '00000000-0000-0000-0000-000000000001';
DELETE FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000001';
SELECT is(payments.end_stale_sessions(), 1, 'a stale session of a deleted author ends');
SELECT is((SELECT credits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000004'), 9::bigint, 'the user is charged the started minute');

-- a folder that is not a uuid is a plain denial, not an error --------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
SELECT throws_ok($$INSERT INTO storage.objects (bucket_id, name) VALUES ('imgs', 'scripts/not-a-uuid/cover.webp')$$, '42501', NULL, 'a non-uuid imgs folder is denied by the policy');
RESET ROLE;

-- privileges -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SELECT throws_ok($$SELECT payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003')$$, '42501', NULL, 'authenticated cannot call start_session');
SELECT throws_ok($$SELECT payments.heartbeat_session(gen_random_uuid())$$, '42501', NULL, 'authenticated cannot call heartbeat_session');
SELECT throws_ok($$SELECT payments.end_session(gen_random_uuid(), 'stopped')$$, '42501', NULL, 'authenticated cannot call end_session');
SELECT throws_ok($$SELECT payments.end_stale_sessions()$$, '42501', NULL, 'authenticated cannot call end_stale_sessions');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
