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

CREATE FUNCTION pg_temp.act(p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_id, 'role', 'authenticated')::text, true);
END;
$$;

CREATE FUNCTION pg_temp.service() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

-- A stable, published, free script with a live revision
CREATE FUNCTION pg_temp.make_script(p_id uuid, p_author uuid) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.act(p_author);
  INSERT INTO scripts.scripts (id, title, description, content, published) VALUES (p_id, 'S ' || p_id, 'd', 'c', true);
  UPDATE scripts.metadata SET stage = 'stable', type = 'free', price = 0 WHERE id = p_id;
  INSERT INTO scripts.versions (id, files) VALUES (p_id, ARRAY['main.luau']);
  INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', p_id || '/000000001/main.luau');
  INSERT INTO scripts.version_keys (id, revision, key) VALUES (p_id, 1, decode(repeat('ab', 32), 'hex'));
  SET LOCAL ROLE authenticated;
  PERFORM scripts.publish_version(p_id, 1);
  PERFORM pg_temp.service();
END;
$$;

-- Stops as the user and returns the answer
CREATE FUNCTION pg_temp.stop(p_id uuid, p_session uuid) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  v boolean;
BEGIN
  PERFORM pg_temp.act(p_id);
  SET LOCAL ROLE authenticated;
  v := payments.stop_session(p_session);
  PERFORM pg_temp.service();
  RETURN v;
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'runner');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'stranger');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'mod', 'moderator');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001');

-- a second instance needs a credit of balance for the fee
SELECT payments.post_credits('00000000-0000-0000-0000-000000000002', 'adjustment', 100);
CREATE TEMP TABLE s (name text PRIMARY KEY, id uuid);
INSERT INTO s SELECT 'a', session_id FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
INSERT INTO s SELECT 'b', session_id FROM payments.start_session('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');

-- a stranger and an anonymous visitor are refused
SELECT throws_ok($$SELECT pg_temp.stop('00000000-0000-0000-0000-000000000003', (SELECT id FROM s WHERE name = 'a'))$$, '42501', 'not allowed', 'another user cannot stop the session');
SELECT throws_ok($$SELECT pg_temp.stop('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000dead')$$, '42501', 'not allowed', 'an unknown session looks the same');
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT payments.stop_session('10000000-0000-0000-0000-000000000001')$$, '42501', NULL, 'anonymous visitors cannot call stop_session');
SELECT pg_temp.service();
SELECT is((SELECT ended_at FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'a')), NULL, 'and the session is still open');

-- the owner stops it
SELECT is(pg_temp.stop('00000000-0000-0000-0000-000000000002', (SELECT id FROM s WHERE name = 'a')), true, 'the owner stops their session');
SELECT is((SELECT end_reason::text FROM payments.sessions WHERE id = (SELECT id FROM s WHERE name = 'a')), 'stopped', 'with reason stopped');
SELECT is(payments.heartbeat_session((SELECT id FROM s WHERE name = 'a')), false, 'so the loader''s next heartbeat tells it to stop');
SELECT is(pg_temp.stop('00000000-0000-0000-0000-000000000002', (SELECT id FROM s WHERE name = 'a')), false, 'stopping again changes nothing');

-- a moderator stops anyone's
SELECT is(pg_temp.stop('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'b')), true, 'a moderator stops another user''s session');

SELECT * FROM finish();
ROLLBACK;
