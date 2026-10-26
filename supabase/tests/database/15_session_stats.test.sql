BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(14);

CREATE FUNCTION pg_temp.signup(p_id uuid, p_name text, p_role profiles.roles DEFAULT 'user') RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_name || '@example.com',
          '{"provider":"discord"}', jsonb_build_object('full_name', p_name));
  UPDATE profiles.profiles SET role = p_role WHERE id = p_id;
END;
$$;

CREATE FUNCTION pg_temp.make_script(p_id uuid, p_author uuid) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_author, 'role', 'authenticated')::text, true);
  INSERT INTO scripts.scripts (id, title, description, content, published) VALUES (p_id, 'S ' || p_id, 'd', 'c', true);
  UPDATE scripts.metadata SET stage = 'stable' WHERE id = p_id;
  UPDATE scripts.protected SET revision = 1, last_revision = 1 WHERE id = p_id;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'runner');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001');

-- Limits: experience 100-1000 and gold 0-0 (none) per minute, two custom trackers with only the second limited
UPDATE stats.limits SET xp_min = 100, xp_max = 1000 WHERE id = '10000000-0000-0000-0000-000000000001';
UPDATE stats.limits_custom SET trackers = '{kills,loot}', minima = '{0,0}', maxima = '{0,50}'
WHERE id = '10000000-0000-0000-0000-000000000001';

INSERT INTO payments.sessions (id, user_id, script_id, author_id, revision, price)
VALUES ('30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002',
        '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 1, 0);
INSERT INTO payments.sessions (id, user_id, script_id, author_id, revision, price, ended_at, end_reason)
VALUES ('30000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002',
        '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 1, 0, now(), 'stopped');

SELECT lives_ok($$SELECT stats.report_session('30000000-0000-0000-0000-000000000001', 500, 70, 1, '{3,20}')$$,
  'a report within the limits is accepted');
SELECT results_eq($$SELECT experience, gold, runtime FROM stats.stats WHERE id = '00000000-0000-0000-0000-000000000002'$$,
  $$VALUES (500::bigint, 70::bigint, 60000::bigint)$$, 'the user totals go up');
SELECT results_eq($$SELECT experience, gold, runtime FROM stats.values WHERE id = '10000000-0000-0000-0000-000000000001'$$,
  $$VALUES (500::bigint, 70::bigint, 60000::bigint)$$, 'the script totals go up');
SELECT results_eq($$SELECT "values" FROM stats.values_custom WHERE id = '10000000-0000-0000-0000-000000000001'$$,
  $$VALUES ('{3,20}'::bigint[])$$, 'the custom trackers are stored');

SELECT lives_ok($$SELECT stats.report_session('30000000-0000-0000-0000-000000000001', 1000, 0, 1, '{1}')$$,
  'fewer custom values than trackers are fine');
SELECT results_eq($$SELECT "values" FROM stats.values_custom WHERE id = '10000000-0000-0000-0000-000000000001'$$,
  $$VALUES ('{4,20}'::bigint[])$$, 'and only add to the first ones');

SELECT throws_ok($$SELECT stats.report_session('30000000-0000-0000-0000-000000000001', 5000, 0, 1)$$, '23514', NULL,
  'experience over the per-minute limit is rejected');
SELECT throws_ok($$SELECT stats.report_session('30000000-0000-0000-0000-000000000001', 50, 0, 1)$$, '23514', NULL,
  'experience under the per-minute minimum is rejected');
SELECT lives_ok($$SELECT stats.report_session('30000000-0000-0000-0000-000000000001', 4000, 999999, 4)$$,
  'limits scale with the minutes reported, and no gold limit means any gold');
SELECT throws_ok($$SELECT stats.report_session('30000000-0000-0000-0000-000000000001', 500, 0, 1, '{0,500}')$$, '23514', NULL,
  'a custom value over its limit is rejected');
SELECT results_eq($$SELECT experience FROM stats.stats WHERE id = '00000000-0000-0000-0000-000000000002'$$,
  $$VALUES (5500::bigint)$$, 'rejected reports change nothing');
SELECT throws_ok($$SELECT stats.report_session('30000000-0000-0000-0000-000000000002', 500, 0, 1)$$, '55000', NULL,
  'an ended session can not report');
SELECT throws_ok($$SELECT stats.report_session('30000000-0000-0000-0000-000000000009', 500, 0, 1)$$, 'P0002', NULL,
  'an unknown session can not report');

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT stats.report_session('30000000-0000-0000-0000-000000000001', 500, 0, 1)$$, '42501', NULL,
  'authenticated users can not report directly');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
