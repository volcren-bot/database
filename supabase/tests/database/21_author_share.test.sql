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

-- A stable, published script with a live revision
CREATE FUNCTION pg_temp.make_script(p_id uuid, p_author uuid, p_price bigint) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_author, 'role', 'authenticated')::text, true);
  INSERT INTO scripts.scripts (id, title, description, content, published) VALUES (p_id, 'S ' || p_id, 'd', 'c', true);
  UPDATE scripts.metadata SET stage = 'stable', type = 'premium', price = p_price WHERE id = p_id;
  INSERT INTO scripts.versions (id, files) VALUES (p_id, ARRAY['main.luau']);
  INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', p_id || '/000000001/main.luau');
  INSERT INTO scripts.version_keys (id, revision, key) VALUES (p_id, 1, decode(repeat('ab', 32), 'hex'));
  SET LOCAL ROLE authenticated;
  PERFORM scripts.publish_version(p_id, 1);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

-- Lets p_minutes of billable time pass for a session and sends its heartbeat
CREATE FUNCTION pg_temp.run(p_session uuid, p_minutes int) RETURNS boolean LANGUAGE sql AS $$
  UPDATE payments.sessions SET charged_until = charged_until - make_interval(mins => p_minutes), last_seen = last_seen - make_interval(mins => p_minutes) WHERE id = p_session;
  SELECT payments.heartbeat_session(p_session);
$$;

CREATE FUNCTION pg_temp.earned(p_session uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(amount), 0)::bigint FROM payments.earnings_ledger WHERE session_id = p_session;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'buyer');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 1);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 22);
SELECT payments.post_credits('00000000-0000-0000-0000-000000000002', 'adjustment', 100000);

CREATE TEMP TABLE s (name text PRIMARY KEY, id uuid);

-- at 1 credit a minute, a minute's 80% is 0.8 of a credit: it is carried, not dropped
INSERT INTO s SELECT 'one', session_id FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
SELECT pg_temp.run((SELECT id FROM s WHERE name = 'one'), 1);
SELECT is(pg_temp.earned((SELECT id FROM s WHERE name = 'one')), 0::bigint, 'the first minute at price 1 is less than a credit of share');
SELECT is((SELECT share_accrued FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'one')), 8000::bigint, 'so the session carries 0.8 of a credit');
SELECT pg_temp.run((SELECT id FROM s WHERE name = 'one'), 1) FROM generate_series(1, 4);
SELECT is(pg_temp.earned((SELECT id FROM s WHERE name = 'one')), 4::bigint, 'five one-minute charges at price 1 pay the author 4 credits, 80%');
SELECT is((SELECT share_accrued FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'one')), 0::bigint, 'with nothing left over');
SELECT is((SELECT count(*) FROM payments.earnings_ledger WHERE session_id = (SELECT id FROM s WHERE name = 'one')), 4::bigint, 'one earnings row per charge that reached a whole credit');
SELECT payments.end_session((SELECT id FROM s WHERE name = 'one'), 'stopped');

-- at 22 a minute the share is 17.6 a minute; ten minutes pay exactly 176
INSERT INTO s SELECT 'max', session_id FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002');
SELECT pg_temp.run((SELECT id FROM s WHERE name = 'max'), 1) FROM generate_series(1, 10);
SELECT is(pg_temp.earned((SELECT id FROM s WHERE name = 'max')), 176::bigint, 'ten one-minute charges at price 22 pay 80% of 220');

-- a single longer charge comes to the same
UPDATE payments.sessions SET share_accrued = 0 WHERE id = (SELECT id FROM s WHERE name = 'max');
SELECT pg_temp.run((SELECT id FROM s WHERE name = 'max'), 5);
SELECT is(pg_temp.earned((SELECT id FROM s WHERE name = 'max')), (176 + 88)::bigint, 'a five-minute charge at price 22 pays 88');
SELECT is((SELECT earnings FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000001'), (4 + 176 + 88)::bigint, 'the author''s earnings balance holds all of it');

SELECT * FROM finish();
ROLLBACK;
