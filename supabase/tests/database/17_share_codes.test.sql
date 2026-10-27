BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(74);

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

CREATE FUNCTION pg_temp.accept(p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.act(p_id);
  SET LOCAL ROLE authenticated;
  PERFORM info.accept_terms('scripter_tos', 1);
  PERFORM info.accept_terms('community_tos', 1);
  RESET ROLE;
END;
$$;

-- Creates a code as the user and returns it
CREATE FUNCTION pg_temp.mkcode(p_id uuid, p_script uuid, p_interval interval DEFAULT interval '1 day') RETURNS text
    LANGUAGE plpgsql AS $$
DECLARE
  v_code text;
BEGIN
  PERFORM pg_temp.act(p_id);
  SET LOCAL ROLE authenticated;
  SELECT c.code INTO v_code FROM scripts.create_share_code(p_script, now() + p_interval) c;
  RESET ROLE;
  RETURN v_code;
END;
$$;

-- Redeems as the user and returns the status
CREATE FUNCTION pg_temp.redeem(p_id uuid, p_code text) RETURNS text
    LANGUAGE plpgsql AS $$
DECLARE
  v_status text;
BEGIN
  PERFORM pg_temp.act(p_id);
  SET LOCAL ROLE authenticated;
  SELECT r.status INTO v_status FROM scripts.redeem_share_code(p_code) r;
  RESET ROLE;
  RETURN v_status;
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'owner', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'tester', 'tester');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'mod', 'moderator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'friend');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000005', 'stranger');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000006', 'cauthor');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000007', 'friend2');

-- an official, premium script and a community one
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 10);
GRANT INSERT ("id") ON TABLE scripts.scripts TO authenticated;
INSERT INTO info.documents (kind, content) VALUES ('scripter_tos', 't'), ('community_tos', 'c');
SELECT pg_temp.accept('00000000-0000-0000-0000-000000000001');
SELECT pg_temp.accept('00000000-0000-0000-0000-000000000003');
SELECT pg_temp.accept('00000000-0000-0000-0000-000000000006');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000006');
SET LOCAL ROLE authenticated;
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000002', 'Community', 'd', 'c');
RESET ROLE;
UPDATE scripts.scripts SET published = false WHERE id = '10000000-0000-0000-0000-000000000001';

-- creating codes -----------------------------------------------------------------------
CREATE TEMP TABLE codes (name text, code text);
GRANT ALL ON codes TO authenticated;

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
INSERT INTO codes SELECT 'first', c.code FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '2 days') c;
SELECT matches((SELECT code FROM codes WHERE name = 'first'), '^[0-9a-f]{64}$', 'a code is 256 random bits in hex');
SELECT is((SELECT expires_at FROM scripts.share_codes WHERE redeemed_at IS NULL), now() + interval '2 days', 'it expires when the owner chose');
SELECT throws_ok($$SELECT code_hash FROM scripts.share_codes$$, '42501', NULL, 'clients cannot read the stored hash');
SELECT throws_ok($$INSERT INTO scripts.share_codes (script_id, code_hash, expires_at) VALUES ('10000000-0000-0000-0000-000000000001', repeat('a', 64), now() + interval '1 day')$$,
  '42501', NULL, 'clients cannot insert codes themselves');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.share_codes WHERE code_hash = (SELECT code FROM codes WHERE name = 'first')), 0, 'the code itself is not stored');
SELECT is((SELECT code_hash FROM scripts.share_codes), encode(extensions.digest((SELECT code FROM codes WHERE name = 'first'), 'sha256'), 'hex'), 'only its SHA-256 is');

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() - interval '1 hour')$$, '23514', NULL, 'an expiry in the past is refused');
SELECT throws_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '31 days')$$, '23514', NULL, 'so is one beyond 30 days');
SELECT throws_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', NULL)$$, '23514', NULL, 'and none at all');
SELECT lives_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '30 days')$$, '30 days is the limit');
SELECT throws_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000009', now() + interval '1 day')$$, '42501', NULL, 'a script that does not exist gives no hint');
RESET ROLE;

SELECT pg_temp.act('00000000-0000-0000-0000-000000000005');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '1 day')$$, '42501', 'not allowed', 'only the author or moderator+ create codes');
SELECT is((SELECT count(*)::int FROM scripts.share_codes), 0, 'and see them');
RESET ROLE;
SELECT lives_ok($$SELECT pg_temp.mkcode('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001')$$, 'a moderator can create codes for any script');

UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000001';
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '1 day')$$, '42501', NULL, 'a banned author cannot create codes');
RESET ROLE;
UPDATE profiles.profiles SET banned_at = NULL WHERE id = '00000000-0000-0000-0000-000000000001';

INSERT INTO info.documents (kind, content) VALUES ('scripter_tos', 't2');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '1 day')$$, '42501', NULL, 'nor can an author on outdated terms');
RESET ROLE;
DELETE FROM info.documents WHERE kind = 'scripter_tos' AND version = 2;

-- at most 20 open codes: 3 exist (first, the 30 days one, the moderator's)
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM scripts.share_codes), 3, 'the author sees the codes of the script');
SELECT lives_ok($$SELECT (scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '1 day')).id FROM generate_series(1, 17)$$, 'a script holds 20 open codes');
SELECT throws_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '1 day')$$, '23514', 'a script can have at most 20 open share codes', 'but not 21');
RESET ROLE;
-- expired and redeemed codes are not open
UPDATE scripts.share_codes SET created_at = now() - interval '2 days', expires_at = now() - interval '1 day'
WHERE id = (SELECT id FROM scripts.share_codes ORDER BY id LIMIT 1);
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT * FROM scripts.create_share_code('10000000-0000-0000-0000-000000000001', now() + interval '1 day')$$, 'an expired code frees a slot');
-- revoking a code
SELECT is((SELECT count(*)::int FROM scripts.share_codes WHERE expires_at > now()), 20, 'twenty codes are open again');
RESET ROLE;

-- redeeming ------------------------------------------------------------------------------
CREATE TEMP TABLE r (c text);
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000004', 'not a code'), 'invalid', 'a malformed code is invalid');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000004', NULL), 'invalid', 'so is no code');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000004', repeat('0', 64)), 'invalid', 'and a code nobody made');
SELECT is((SELECT count(*)::int FROM scripts.redeem_attempts WHERE user_id = '00000000-0000-0000-0000-000000000004'), 3, 'failed attempts are counted');

SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000001', (SELECT code FROM codes WHERE name = 'first')), 'own', 'the owner cannot redeem their own code');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000003', (SELECT code FROM codes WHERE name = 'first')), 'already_access', 'nor can someone who can already see the script (moderator+)');
SELECT is((SELECT count(*)::int FROM scripts.share_codes WHERE redeemed_at IS NOT NULL), 0, 'those leave the code unused');
SELECT is((SELECT count(*)::int FROM scripts.redeem_attempts WHERE user_id IN ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003')), 0, 'and are not failed attempts');

SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001'), 'an unpublished script is hidden from the friend');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000004', upper((SELECT code FROM codes WHERE name = 'first'))), 'ok', 'a valid code is redeemed (copy-paste case is forgiven)');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001'), 'and opens the script');
SELECT is((SELECT redeemed_by FROM scripts.share_codes WHERE redeemed_at IS NOT NULL), '00000000-0000-0000-0000-000000000004'::uuid, 'the code records who redeemed it');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000005', (SELECT code FROM codes WHERE name = 'first')), 'used', 'nobody else can use it');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000004', (SELECT code FROM codes WHERE name = 'first')), 'used', 'nor can the same person again');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001'), 'the second user got nothing');

-- expired codes
INSERT INTO scripts.share_codes (script_id, code_hash, created_by, created_at, expires_at)
VALUES ('10000000-0000-0000-0000-000000000001', encode(extensions.digest(repeat('e', 64), 'sha256'), 'hex'), '00000000-0000-0000-0000-000000000001', now() - interval '2 days', now() - interval '1 day');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000005', repeat('e', 64)), 'expired', 'an expired code says so');

-- the rate limit
UPDATE scripts.config SET redeem_max_failures = 4;
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000005', repeat('1', 64)), 'invalid', 'another failure');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000005', repeat('2', 64)), 'invalid', 'and another');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000005', repeat('3', 64)), 'rate_limited', 'then the account is cut off');
SELECT pg_temp.mkcode('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000005', (SELECT code FROM codes WHERE name = 'first')), 'rate_limited', 'even for a code that would work');
UPDATE scripts.redeem_attempts SET attempted_at = now() - interval '2 hours';
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000005', repeat('3', 64)), 'invalid', 'the limit lifts once the window has passed');
UPDATE scripts.config SET redeem_max_failures = 10;

-- banned people
UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000005';
SELECT throws_ok($$SELECT pg_temp.redeem('00000000-0000-0000-0000-000000000005', repeat('4', 64))$$, '42501', 'not allowed', 'a banned account cannot redeem');
UPDATE profiles.profiles SET banned_at = NULL WHERE id = '00000000-0000-0000-0000-000000000005';

SELECT pg_temp.act('00000000-0000-0000-0000-000000000006');
SET LOCAL ROLE authenticated;
INSERT INTO codes SELECT 'community', c.code FROM scripts.create_share_code('10000000-0000-0000-0000-000000000002', now() + interval '1 day') c;
RESET ROLE;
UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000006';
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000005', (SELECT code FROM codes WHERE name = 'community')), 'invalid', 'a code of a banned author is invalid');
UPDATE profiles.profiles SET banned_at = NULL WHERE id = '00000000-0000-0000-0000-000000000006';
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000005', (SELECT code FROM codes WHERE name = 'community')), 'ok', 'and valid again once unbanned');
SELECT ok(scripts.can_view('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002'), 'codes work for community scripts');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000002'), 'and only for whoever redeemed them');

-- who is told what ------------------------------------------------------------------------
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((SELECT array_agg(username) FROM scripts.list_grantees('10000000-0000-0000-0000-000000000001')), ARRAY['friend'], 'the owner lists who redeemed, by username');
SELECT is((SELECT count(*)::int FROM scripts.grants), 1, 'and sees the grants');
SELECT throws_ok($$SELECT user_id, code_id FROM scripts.grants$$, '42501', NULL, 'but not which code made them');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000005');
SELECT is((SELECT count(*)::int FROM scripts.list_grantees('10000000-0000-0000-0000-000000000001')), 0, 'others get no grantee list');
SELECT is((SELECT count(*)::int FROM scripts.grants), 1, 'a holder sees only their own grant');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000003');
SELECT is((SELECT count(*)::int FROM scripts.list_grantees('10000000-0000-0000-0000-000000000001')), 1, 'a moderator lists any script''s grantees');
RESET ROLE;

-- running: grantees pay nothing, banned authors stop --------------------------------------
UPDATE scripts.scripts SET published = true WHERE id = '10000000-0000-0000-0000-000000000001';
SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
CREATE TEMP TABLE s (id uuid, revision int, files text[], entry text);
INSERT INTO s SELECT * FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
SELECT is((SELECT price FROM payments.sessions WHERE id = (SELECT id FROM s)), 0::bigint, 'a grantee runs a premium script at price 0 without credits');
SELECT throws_ok($$SELECT * FROM payments.start_session('00000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001')$$, '42501', 'script not accessible', 'while someone without a grant or credits cannot');
UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000001';
SELECT is(payments.heartbeat_session((SELECT id FROM s)), false, 'a running session stops when the author is banned');
SELECT ok((SELECT ended_at IS NOT NULL FROM payments.sessions WHERE id = (SELECT id FROM s)), 'and is ended');
SELECT throws_ok($$SELECT * FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001')$$, '42501', 'script not accessible', 'a banned author''s script cannot start a session');
SELECT throws_ok($$SELECT * FROM payments.start_session('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001')$$, '42501', 'script not accessible', 'not even for a moderator');
UPDATE profiles.profiles SET banned_at = NULL WHERE id = '00000000-0000-0000-0000-000000000001';

-- revoking ------------------------------------------------------------------------------
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
DELETE FROM scripts.share_codes WHERE redeemed_at IS NOT NULL;
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.share_codes WHERE redeemed_at IS NOT NULL), 2, 'a redeemed code cannot be deleted');
SET LOCAL ROLE authenticated;
DELETE FROM scripts.share_codes WHERE id = (SELECT id FROM scripts.share_codes WHERE redeemed_at IS NULL AND expires_at > now() ORDER BY id LIMIT 1);
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.share_codes WHERE redeemed_at IS NULL AND expires_at > now() AND script_id = '10000000-0000-0000-0000-000000000001'), 19, 'an unused code is revoked');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000005');
SET LOCAL ROLE authenticated;
DELETE FROM scripts.grants WHERE user_id = '00000000-0000-0000-0000-000000000004';
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.grants WHERE script_id = '10000000-0000-0000-0000-000000000001'), 1, 'someone else cannot remove a grant');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
DELETE FROM scripts.grants WHERE user_id = '00000000-0000-0000-0000-000000000004';
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.grants WHERE script_id = '10000000-0000-0000-0000-000000000001'), 0, 'the owner revokes a grant');
SELECT ok(NOT scripts.has_grant('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001'), 'and the grant is gone');
SELECT is(pg_temp.redeem('00000000-0000-0000-0000-000000000004', (SELECT code FROM codes WHERE name = 'first')), 'used', 'the code is not usable again');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000005');
SET LOCAL ROLE authenticated;
DELETE FROM scripts.grants WHERE script_id = '10000000-0000-0000-0000-000000000002';
RESET ROLE;
SELECT is((SELECT count(*)::int FROM scripts.grants WHERE script_id = '10000000-0000-0000-0000-000000000002'), 0, 'a recipient removes the script from their account');
SELECT ok(NOT scripts.can_view('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002'), 'and loses it');

-- cleanup and cascades -----------------------------------------------------------------------
INSERT INTO scripts.share_codes (script_id, code_hash, created_by, created_at, expires_at)
VALUES ('10000000-0000-0000-0000-000000000001', repeat('c', 64), '00000000-0000-0000-0000-000000000001', now() - interval '2 days', now() - interval '1 day');
UPDATE scripts.redeem_attempts SET attempted_at = now() - interval '2 hours' WHERE user_id = '00000000-0000-0000-0000-000000000004';
SELECT cmp_ok(scripts.delete_expired_share_codes(), '>=', 2, 'the cleanup job drops expired unredeemed codes');
SELECT is((SELECT count(*)::int FROM scripts.share_codes WHERE redeemed_at IS NULL AND expires_at < now()), 0, 'none are left');
SELECT is((SELECT count(*)::int FROM scripts.share_codes WHERE redeemed_at IS NOT NULL), 2, 'redeemed ones stay');
SELECT is((SELECT count(*)::int FROM scripts.redeem_attempts WHERE user_id = '00000000-0000-0000-0000-000000000004'), 0, 'old failed attempts go too');
SELECT cmp_ok((SELECT count(*)::int FROM scripts.redeem_attempts), '>', 0, 'but recent ones stay');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT throws_ok($$SELECT scripts.delete_expired_share_codes()$$, '42501', NULL, 'clients cannot run the cleanup');
RESET ROLE;
DELETE FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000002';
SELECT is((SELECT count(*)::int FROM scripts.share_codes WHERE script_id = '10000000-0000-0000-0000-000000000002'), 0, 'codes are deleted with their script');

SELECT * FROM finish();
ROLLBACK;
