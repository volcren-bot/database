BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(9);

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
  SET LOCAL ROLE authenticated;
  PERFORM scripts.publish_version(p_id, 1);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'user');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'earner');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'unpaid author', 'scripter');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 10);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000004', 0);
SELECT payments.post_credits('00000000-0000-0000-0000-000000000002', 'adjustment', 1000);
SELECT payments.post_earnings('00000000-0000-0000-0000-000000000003', 'adjustment', 5);

-- deleting a user ends and charges their running scripts --------------------------------
CREATE TEMP TABLE s (id uuid, revision int, files text[]);
INSERT INTO s SELECT * FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
UPDATE payments.sessions SET started_at = started_at - interval '3 minutes', charged_until = charged_until - interval '3 minutes';

SELECT lives_ok($$DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000002'$$, 'a user can be deleted');
SELECT is((SELECT count(*)::int FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-000000000002'), 0, 'their profile goes with them');
SELECT is((SELECT count(*)::int FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000002'), 0, 'and their balance');
SELECT is((SELECT end_reason FROM payments.sessions WHERE id = (SELECT id FROM s)), 'stopped'::payments.session_end, 'their running session was ended');
SELECT is((SELECT sum(amount)::bigint FROM payments.credits_ledger WHERE session_id = (SELECT id FROM s)), -30::bigint,
  'and charged for its minutes before the balance went');
SELECT is((SELECT earnings FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000001'), 24::bigint, 'so the author was paid');
SELECT is((SELECT count(*)::int FROM payments.credits_ledger WHERE user_id = '00000000-0000-0000-0000-000000000002'), 2, 'the ledger outlives the account');

-- what blocks a deletion --------------------------------------------------------------
SELECT throws_ok($$DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000004'$$, '23503', NULL,
  'a scripter who still authors scripts cannot be deleted');
SELECT throws_ok($$DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000003'$$, '23001', NULL,
  'an account holding earnings cannot be deleted');

SELECT * FROM finish();
ROLLBACK;
