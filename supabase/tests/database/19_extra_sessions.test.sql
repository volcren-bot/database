BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(45);

CREATE FUNCTION pg_temp.signup(p_id uuid, p_name text, p_role profiles.roles DEFAULT 'user') RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_name || '@example.com',
          '{"provider":"discord"}', jsonb_build_object('full_name', p_name));
  UPDATE profiles.profiles SET role = p_role WHERE id = p_id;
END;
$$;

-- A stable, published script with a live revision
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

-- Lets p_by of billable time pass for a session; started_at stays, so the rank order does too
CREATE FUNCTION pg_temp.age(p_session uuid, p_by interval) RETURNS void LANGUAGE sql AS $$
  UPDATE payments.sessions SET charged_until = charged_until - p_by, last_seen = last_seen - p_by WHERE id = p_session;
$$;

-- Sessions started in one transaction share now(): spread their start times so the rank order is known
CREATE FUNCTION pg_temp.older(p_session uuid, p_by interval) RETURNS void LANGUAGE sql AS $$
  UPDATE payments.sessions SET started_at = started_at - p_by WHERE id = p_session;
$$;

CREATE FUNCTION pg_temp.credits(p_user uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT microcredits FROM payments.accounts WHERE user_id = p_user;
$$;

UPDATE payments.config SET extra_session_fee = 30000;
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'farmer');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'tester', 'tester');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'bonus');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000005', 'poor');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000006', 'admin', 'administrator');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 600);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 0);
SELECT payments.post_credits('00000000-0000-0000-0000-000000000002', 'adjustment', 100000);

CREATE TEMP TABLE s (name text PRIMARY KEY, id uuid, rank int, fee bigint);

-- the quote and the rank
SELECT results_eq($$SELECT price, rank, fee, required FROM payments.session_quote('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001')$$,
  $$VALUES (600::bigint, 0, 0::bigint, 10::bigint)$$, 'the first instance is quoted at the script price with no fee');
INSERT INTO s SELECT 'a', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 'a'), interval '3 seconds');
SELECT is((SELECT (rank, fee) FROM s WHERE name = 'a'), (0, 0::bigint), 'start_session returns rank 0 and no fee for the first session');
SELECT results_eq($$SELECT price, rank, fee, required FROM payments.session_quote('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001')$$,
  $$VALUES (600::bigint, 1, 30000::bigint, 11::bigint)$$, 'the second instance is quoted with the monthly fee and a credit more of balance');
INSERT INTO s SELECT 'b', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 'b'), interval '2 seconds');
INSERT INTO s SELECT 'c', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 'c'), interval '1 second');
SELECT is((SELECT (rank, fee) FROM s WHERE name = 'b'), (1, 30000::bigint), 'the second session starts at rank 1 with the fee');
SELECT is((SELECT (rank, fee) FROM s WHERE name = 'c'), (2, 30000::bigint), 'and a third, on a free script, at rank 2 with the fee');
SELECT is(payments.session_rank((SELECT id FROM s WHERE name = 'a')), 0, 'the oldest open session ranks 0');
SELECT is(payments.session_rank((SELECT id FROM s WHERE name = 'c')), 2, 'the newest ranks 2');

-- a day of the second instance: 1440 minutes of price plus exactly 1000 credits of fee (30000 x 1440 / 43200)
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'b'), interval '1440 minutes');
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 'b')), true, 'a heartbeat on the second instance keeps it running');
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000002'), (100000 - 14400 - 1000)::bigint, 'a day costs the price plus 1000 credits of fee');
SELECT is((SELECT (amount, fee, bonus) FROM payments.credits_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'b')), (-15400::bigint, 1000::bigint, 0::bigint), 'the ledger row records the fee part');
SELECT is((SELECT (fee_accrued, fee_charged) FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'b')), (0::bigint, 1000::bigint), 'the session carries no remainder and remembers the fee charged');
SELECT is((SELECT amount FROM payments.earnings_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'b')), 11520::bigint, 'the author gets 80% of the price part only');

-- the fee accrues in credit-minutes and is charged a whole credit at a time
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'c'), interval '1 minute');
SELECT payments.heartbeat_session((SELECT id FROM s WHERE name = 'c'));
SELECT is((SELECT fee_accrued FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'c')), 30000::bigint, 'one minute of fee is not a whole credit yet');
SELECT is((SELECT count(*) FROM payments.credits_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'c')), 0::bigint, 'so nothing is charged on the free script');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'c'), interval '1 minute');
SELECT payments.heartbeat_session((SELECT id FROM s WHERE name = 'c'));
SELECT is((SELECT (fee_accrued, fee_charged) FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'c')), (16800::bigint, 1::bigint), 'the second minute tips it over: one credit charged, the rest carried');
SELECT is((SELECT (amount, fee) FROM payments.credits_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'c')), (-1::bigint, 1::bigint), 'a free script''s extra instance pays only the fee');
SELECT is((SELECT count(*) FROM payments.earnings_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'c')), 0::bigint, 'and the author earns nothing from a fee');

-- the rank follows the open sessions: once the oldest ends, the next one is free
SELECT payments.end_session((SELECT id FROM s WHERE name = 'a'), 'stopped');
SELECT is(payments.session_rank((SELECT id FROM s WHERE name = 'b')), 0, 'the second session moves up to rank 0');
SELECT is(payments.session_rank((SELECT id FROM s WHERE name = 'c')), 1, 'and the third to rank 1');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'b'), interval '1440 minutes');
SELECT payments.heartbeat_session((SELECT id FROM s WHERE name = 'b'));
SELECT is((SELECT fee FROM payments.credits_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'b') ORDER BY id DESC LIMIT 1), 0::bigint, 'a day at rank 0 carries no fee');
SELECT is((SELECT fee_charged FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'b')), 1000::bigint, 'and the fee charged so far stays');
SELECT payments.end_session(id, 'stopped') FROM s WHERE name IN ('b', 'c');

-- the balance has to cover a minute of the price and a credit of fee
SELECT payments.post_credits('00000000-0000-0000-0000-000000000005', 'adjustment', 20);
INSERT INTO s SELECT 'p1', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 'p1'), interval '3 seconds');
SELECT payments.post_credits('00000000-0000-0000-0000-000000000005', 'adjustment', -10);
SELECT throws_ok($$SELECT payments.start_session('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001')$$, '23514', 'insufficient credits', 'a second instance needs the price plus a credit for the fee');
SELECT payments.post_credits('00000000-0000-0000-0000-000000000005', 'adjustment', 1);
INSERT INTO s SELECT 'p2', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 'p2'), interval '2 seconds');
SELECT is((SELECT rank FROM s WHERE name = 'p2'), 1, 'with that credit it starts');
SELECT payments.post_credits('00000000-0000-0000-0000-000000000005', 'adjustment', -11);
SELECT throws_ok($$SELECT payments.start_session('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002')$$, '23514', 'insufficient credits', 'an extra instance of a free script needs a credit of balance');
SELECT payments.post_credits('00000000-0000-0000-0000-000000000005', 'adjustment', 1);
INSERT INTO s SELECT 'p3', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 'p3'), interval '1 seconds');
SELECT is((SELECT rank FROM s WHERE name = 'p3'), 2, 'there is no cap on open sessions');
SELECT payments.post_credits('00000000-0000-0000-0000-000000000005', 'adjustment', -1);
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'p3'), interval '1 minute');
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 'p3')), false, 'a heartbeat ends an extra instance whose balance can''t cover the fee');
SELECT is((SELECT end_reason::text FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'p3')), 'insufficient_credits', 'with the matching reason');
SELECT payments.end_user_sessions('00000000-0000-0000-0000-000000000005');

-- tester+ run as many as they like for free
INSERT INTO s SELECT 't1', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 't1'), interval '2 seconds');
INSERT INTO s SELECT 't2', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 't2'), interval '1 seconds');
SELECT is((SELECT (rank, fee) FROM s WHERE name = 't2'), (1, 0::bigint), 'a tester''s second session ranks 1 but has no fee');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 't2'), interval '1440 minutes');
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 't2')), true, 'and keeps running with no balance');
SELECT is((SELECT count(*) FROM payments.credits_ledger WHERE user_id = '00000000-0000-0000-0000-000000000003'), 0::bigint, 'with nothing charged');
SELECT payments.end_user_sessions('00000000-0000-0000-0000-000000000003');

-- bonus credits: a top-up with a bonus is remembered, spent in proportion, and the author's share on it is lost
INSERT INTO payments.payments (id, user_id, provider, provider_id, microcredits, bonus, amount)
VALUES ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', 'bitcart', 'inv-1', 11000, 1000, 1000);
SELECT payments.settle_payment('20000000-0000-0000-0000-000000000001');
SELECT is((SELECT (microcredits, bonus_microcredits) FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000004'), (11000::bigint, 1000::bigint), 'settling a payment records its bonus');
SELECT is((SELECT bonus FROM payments.credits_ledger WHERE payment_id = '20000000-0000-0000-0000-000000000001'), 1000::bigint, 'and the ledger row carries it');
INSERT INTO s SELECT 'k', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 'k'), interval '5 seconds');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'k'), interval '100 minutes');
SELECT payments.heartbeat_session((SELECT id FROM s WHERE name = 'k'));
SELECT is((SELECT (amount, bonus) FROM payments.credits_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'k')), (-1000::bigint, -90::bigint), '1000 credits spent from a balance that is 1/11 bonus take 90 bonus credits');
SELECT is((SELECT (microcredits, bonus_microcredits) FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000004'), (10000::bigint, 910::bigint), 'the account keeps the rest');
SELECT is((SELECT (amount, bonus) FROM payments.earnings_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'k')), (728::bigint, 72::bigint), 'the author is paid 800 less the 9% paid with bonus, which is recorded as lost');
SELECT is((SELECT earnings FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000001'), (23040 + 728)::bigint, 'and the earnings balance moved by the paid part only: two days of the second instance and this sale');
SELECT payments.end_session((SELECT id FROM s WHERE name = 'k'), 'stopped');

-- other spending takes bonus credits in proportion too, gains bring none
SELECT payments.adjust_credits('00000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000004', -1000, 'test');
SELECT is((SELECT (microcredits, bonus_microcredits) FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000004'), (9000::bigint, 819::bigint), 'an adjustment down takes its share of bonus credits');
SELECT payments.adjust_credits('00000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000004', 1000, 'test');
SELECT is((SELECT (microcredits, bonus_microcredits) FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000004'), (10000::bigint, 819::bigint), 'an adjustment up adds no bonus');
SELECT payments.post_earnings('00000000-0000-0000-0000-000000000004', 'adjustment', 500);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
SELECT payments.transfer_earnings(500);
SELECT set_config('request.jwt.claims', '', true);
SELECT is((SELECT (microcredits, bonus_microcredits) FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000004'), (10500::bigint, 819::bigint), 'earnings moved to credits are not bonus');

-- a share that is all bonus is recorded with a zero amount
UPDATE payments.accounts SET bonus_microcredits = microcredits WHERE user_id = '00000000-0000-0000-0000-000000000004';
INSERT INTO s SELECT 'm', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 'm'), interval '4 seconds');
SELECT pg_temp.age((SELECT id FROM s WHERE name = 'm'), interval '10 minutes');
SELECT payments.heartbeat_session((SELECT id FROM s WHERE name = 'm'));
SELECT is((SELECT (amount, bonus) FROM payments.earnings_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'm')), (0::bigint, 80::bigint), 'a sale paid entirely with bonus credits pays the author nothing and records the whole share as lost');
SELECT is((SELECT (microcredits, bonus_microcredits) FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000004'), (10400::bigint, 10400::bigint), 'and the balance stays all bonus');
SELECT payments.end_session((SELECT id FROM s WHERE name = 'm'), 'stopped');

-- the fee is config
UPDATE payments.config SET extra_session_fee = 0;
SELECT results_eq($$SELECT rank, fee, required FROM payments.session_quote('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002')$$,
  $$VALUES (0, 0::bigint, 0::bigint)$$, 'with no open sessions a free script needs nothing');
INSERT INTO s SELECT 'z', session_id, rank, fee FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002');
SELECT pg_temp.older((SELECT id FROM s WHERE name = 'z'), interval '3 seconds');
SELECT results_eq($$SELECT rank, fee, required FROM payments.session_quote('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002')$$,
  $$VALUES (1, 0::bigint, 0::bigint)$$, 'a fee of zero turns the extra-session charge off');

-- clients can't call the billing functions
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT payments.session_quote('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001')$$, '42501', NULL, 'clients cannot quote sessions');
SELECT throws_ok($$SELECT payments.session_rank('00000000-0000-0000-0000-000000000002')$$, '42501', NULL, 'nor read ranks');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
