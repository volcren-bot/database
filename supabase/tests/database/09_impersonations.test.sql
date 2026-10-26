BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(13);

CREATE FUNCTION pg_temp.signup(p_id uuid, p_name text, p_role profiles.roles DEFAULT 'user') RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_name || '@example.com',
          '{"provider":"discord"}', jsonb_build_object('full_name', p_name));
  UPDATE profiles.profiles SET role = p_role WHERE id = p_id;
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'admin', 'administrator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'admin2', 'administrator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'mod', 'moderator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'user');

-- who can impersonate whom -------------------------------------------------------------
SELECT lives_ok($$SELECT profiles.log_impersonation('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004')$$,
  'an administrator can impersonate a user');
SELECT lives_ok($$SELECT profiles.log_impersonation('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003')$$,
  'and a moderator');
SELECT results_eq(
  $$SELECT admin_id, user_id FROM profiles.impersonations ORDER BY id$$,
  $$VALUES ('00000000-0000-0000-0000-000000000001'::uuid, '00000000-0000-0000-0000-000000000004'::uuid),
           ('00000000-0000-0000-0000-000000000001'::uuid, '00000000-0000-0000-0000-000000000003'::uuid)$$,
  'each impersonation is recorded with the administrator and the user');

SELECT throws_ok($$SELECT profiles.log_impersonation('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002')$$,
  '42501', 'administrators cannot be impersonated', 'an administrator cannot impersonate another administrator');
SELECT throws_ok($$SELECT profiles.log_impersonation('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001')$$,
  '42501', 'administrators cannot be impersonated', 'or themselves');
SELECT throws_ok($$SELECT profiles.log_impersonation('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000004')$$,
  '42501', 'only administrators can impersonate', 'a moderator cannot impersonate');
SELECT throws_ok($$SELECT profiles.log_impersonation(NULL, '00000000-0000-0000-0000-000000000004')$$,
  '42501', 'only administrators can impersonate', 'an impersonation needs an administrator');
SELECT throws_ok($$SELECT profiles.log_impersonation('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000009')$$,
  'P0002', NULL, 'an unknown user cannot be impersonated');
SELECT is((SELECT count(*)::int FROM profiles.impersonations), 2, 'refused impersonations are not recorded');

-- the record is append-only and private -------------------------------------------------
SELECT throws_like($$DELETE FROM profiles.impersonations$$, '%append-only%', 'records cannot be deleted');
SELECT throws_like($$UPDATE profiles.impersonations SET user_id = admin_id$$, '%append-only%', 'or changed');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM profiles.impersonations$$, '42501', NULL, 'clients cannot read the record, not even administrators');
SELECT throws_ok($$SELECT profiles.log_impersonation('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004')$$,
  '42501', NULL, 'clients cannot record impersonations');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
