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

-- A script by the author at p_price credits a minute; p_live gives it a live revision
CREATE FUNCTION pg_temp.make_script(p_id uuid, p_price bigint, p_stage scripts.stage, p_published boolean, p_live boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  INSERT INTO scripts.scripts (id, title, description, content, published) VALUES (p_id, 'S ' || p_id, 'd', 'c', p_published);
  UPDATE scripts.metadata
  SET stage = p_stage, price = p_price, type = CASE WHEN p_price > 0 THEN 'premium'::scripts.type ELSE 'free'::scripts.type END
  WHERE id = p_id;
  IF p_live THEN
    UPDATE scripts.protected SET revision = 1, last_revision = 1 WHERE id = p_id;
  END IF;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'buyer');

SELECT is(payments.average_price(), NULL, 'no paid scripts: no average');

-- Counted: paid, published, beta or stable, live
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', 10, 'stable', true);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000002', 20, 'beta', true);
-- Not counted
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000003', 0, 'stable', true);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000004', 22, 'stable', false);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000005', 5, 'prototype', true);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000006', 7, 'alpha', true);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000007', 3, 'archived', true);
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000008', 1, 'stable', true, false);

SELECT is(payments.average_price(), 15::numeric,
  'only paid, published, beta or stable scripts with a live revision are averaged');

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(payments.average_price(), 15::numeric, 'a logged-in user gets the same average, unhidden by RLS');
RESET ROLE;

SET LOCAL ROLE anon;
SELECT throws_ok('SELECT payments.average_price()', '42501', NULL, 'anonymous visitors cannot call it');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
