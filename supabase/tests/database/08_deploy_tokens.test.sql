BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(22);

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

CREATE FUNCTION pg_temp.act_service() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'other', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'mod', 'moderator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'plain');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000001', 'Mining', 'd', 'c', true);
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000002', 'Fishing', 'd', 'c', true);

-- managing tokens ----------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT lives_ok($$INSERT INTO scripts.deploy_tokens (script_id, name, token_hash) VALUES ('10000000-0000-0000-0000-000000000001', 'ci', repeat('a', 64))$$, 'the author can create a deploy token');
SELECT is((SELECT created_by FROM scripts.deploy_tokens WHERE name = 'ci'), '00000000-0000-0000-0000-000000000001'::uuid, 'created_by is the caller');
SELECT throws_ok($$INSERT INTO scripts.deploy_tokens (script_id, name, token_hash, created_by) VALUES ('10000000-0000-0000-0000-000000000001', 'forged', repeat('d', 64), '00000000-0000-0000-0000-000000000003')$$, '42501', NULL, 'created_by cannot be forged');
SELECT throws_ok($$SELECT token_hash FROM scripts.deploy_tokens$$, '42501', NULL, 'clients cannot read token hashes');
SELECT throws_ok($$INSERT INTO scripts.deploy_tokens (script_id, name, token_hash) VALUES ('10000000-0000-0000-0000-000000000001', '', repeat('d', 64))$$, '23514', NULL, 'a token needs a name');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SELECT throws_ok($$INSERT INTO scripts.deploy_tokens (script_id, name, token_hash) VALUES ('10000000-0000-0000-0000-000000000001', 'x', repeat('d', 64))$$, '42501', NULL, 'another scripter cannot create tokens for the script');
SELECT is((SELECT count(*)::int FROM scripts.deploy_tokens), 0, 'nor see them');
DELETE FROM scripts.deploy_tokens;

SELECT pg_temp.act('00000000-0000-0000-0000-000000000003');
SELECT lives_ok($$INSERT INTO scripts.deploy_tokens (script_id, name, token_hash) VALUES ('10000000-0000-0000-0000-000000000001', 'mod', repeat('b', 64))$$, 'a moderator can create a token for any script');
SELECT is((SELECT count(*)::int FROM scripts.deploy_tokens), 2, 'and sees all of its tokens');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
DELETE FROM scripts.deploy_tokens;
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.deploy_tokens), 2, 'other users revoked nothing');

-- checking tokens --------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT throws_ok($$SELECT scripts.use_deploy_token('10000000-0000-0000-0000-000000000001', repeat('a', 64))$$, '42501', NULL, 'clients cannot call use_deploy_token');
RESET ROLE;

SET LOCAL ROLE service_role;
SELECT pg_temp.act_service();
SELECT isnt(scripts.use_deploy_token('10000000-0000-0000-0000-000000000001', repeat('a', 64)), NULL::uuid, 'a valid token is accepted');
SELECT ok((SELECT last_used_at IS NOT NULL FROM scripts.deploy_tokens WHERE name = 'ci'), 'its use is recorded');
SELECT throws_ok($$SELECT scripts.use_deploy_token('10000000-0000-0000-0000-000000000001', repeat('c', 64))$$, '42501', 'invalid deploy token', 'an unknown token is rejected');
SELECT throws_ok($$SELECT scripts.use_deploy_token('10000000-0000-0000-0000-000000000002', repeat('a', 64))$$, '42501', 'invalid deploy token', 'a token only works for its own script');

-- publishing as service_role -----------------------------------------------------------
INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau']);
INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000001/main.luau');
SELECT lives_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1)$$, 'service_role can publish');
INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau']);
SELECT lives_ok($$SELECT scripts.discard_version('10000000-0000-0000-0000-000000000001', 2)$$, 'and discard');
RESET ROLE;
SELECT is((SELECT revision FROM scripts.protected WHERE id = '10000000-0000-0000-0000-000000000001'), 1, 'the revision went live');

INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau']);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"role":"authenticated"}', true);
SELECT throws_ok($$SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 3)$$, '42501', 'not allowed', 'a caller that is neither a user nor service_role still cannot publish');
RESET ROLE;

-- losing access ------------------------------------------------------------------------
UPDATE profiles.profiles SET role = 'user' WHERE id = '00000000-0000-0000-0000-000000000003';
SET LOCAL ROLE service_role;
SELECT pg_temp.act_service();
SELECT throws_ok($$SELECT scripts.use_deploy_token('10000000-0000-0000-0000-000000000001', repeat('b', 64))$$, '42501', 'invalid deploy token', 'a token stops working once its creator may no longer publish the script');
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
DELETE FROM scripts.deploy_tokens WHERE name = 'ci';
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT pg_temp.act_service();
SELECT throws_ok($$SELECT scripts.use_deploy_token('10000000-0000-0000-0000-000000000001', repeat('a', 64))$$, '42501', 'invalid deploy token', 'a revoked token is rejected');
RESET ROLE;

DELETE FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000001';
SELECT is((SELECT count(*)::int FROM scripts.deploy_tokens WHERE script_id = '10000000-0000-0000-0000-000000000001'), 0, 'tokens are deleted with their script');

SELECT * FROM finish();
ROLLBACK;
