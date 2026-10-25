BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(26);

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

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'user');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'tester', 'tester');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'scripter', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000005', 'moderator', 'moderator');

-- a published stable script by "author" (fixtures are written as postgres with the author's claims)
SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000001', 'Mining', 'd', 'c', true);
UPDATE scripts.metadata SET stage = 'stable' WHERE id = '10000000-0000-0000-0000-000000000001';
INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau']);
-- a draft (revision 0) script
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('10000000-0000-0000-0000-000000000002', 'Draft', 'd', 'c');
-- give the first script a live revision
INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000001/main.luau');
SET LOCAL ROLE authenticated;
SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1);
RESET ROLE;

-- RLS per role -------------------------------------------------------------
SELECT set_config('request.jwt.claims', '', true);
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::int FROM scripts.scripts), 1, 'anon sees the published script only');
SELECT is((SELECT count(*)::int FROM scripts.versions), 0, 'anon cannot read versions');
SELECT throws_ok($$SELECT * FROM payments.accounts$$, '42501', NULL, 'anon has no access to payments');
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT is((SELECT count(*)::int FROM scripts.scripts), 1, 'a user does not see another author''s draft');
SELECT is((SELECT count(*)::int FROM scripts.versions), 0, 'a user cannot read versions');
SELECT is((SELECT count(*)::int FROM payments.accounts), 1, 'a user sees only their own account');
SELECT throws_ok($$INSERT INTO scripts.scripts (title, description, content) VALUES ('x', 'x', 'x')$$, '42501', NULL, 'a plain user cannot create scripts');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'scripts'), 0, 'a user cannot read the scripts bucket');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
SELECT is((SELECT count(*)::int FROM scripts.scripts), 2, 'the author sees both of their scripts');
SELECT is((SELECT count(*)::int FROM scripts.versions), 1, 'the author reads the versions');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'scripts'), 1, 'the author reads the scripts bucket');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000003');
SELECT is((SELECT count(*)::int FROM scripts.scripts), 1, 'another scripter does not see the draft');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'scripts'), 0, 'another scripter cannot read the bucket');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000005');
SELECT is((SELECT count(*)::int FROM scripts.scripts), 2, 'a moderator sees every script');
SELECT is((SELECT count(*)::int FROM scripts.versions), 1, 'a moderator reads the versions');
RESET ROLE;

-- column grants ------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
SELECT throws_ok($$UPDATE profiles.profiles SET role = 'administrator' WHERE id = '00000000-0000-0000-0000-000000000004'$$, '42501', NULL, 'a client cannot write role');
SELECT throws_ok($$UPDATE scripts.protected SET author = '00000000-0000-0000-0000-000000000003'$$, '42501', NULL, 'a client cannot write author');
SELECT throws_ok($$UPDATE scripts.protected SET revision = 9$$, '42501', NULL, 'a client cannot write revision');

-- stage can't go backwards
SELECT throws_ok($$UPDATE scripts.metadata SET stage = 'alpha' WHERE id = '10000000-0000-0000-0000-000000000001'$$, '23514', NULL, 'stage cannot go backwards');
RESET ROLE;

-- ledgers and payments ----------------------------------------------------
INSERT INTO payments.payments (id, user_id, provider, provider_id, credits, amount)
VALUES ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'bitcart', 'inv-1', 50000, 500);

SELECT is(payments.settle_payment('20000000-0000-0000-0000-000000000001'), true, 'settle_payment settles');
SELECT is(payments.settle_payment('20000000-0000-0000-0000-000000000001'), false, 'settle_payment is idempotent');
SELECT is((SELECT credits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000001'), 50000::bigint, 'credits are granted once');

SELECT payments.post_earnings('00000000-0000-0000-0000-000000000004', 'adjustment', 100);
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
SELECT throws_ok($$SELECT payments.transfer_earnings(500)$$, '23514', NULL, 'transfer_earnings rejects more than the balance');
SELECT is(payments.transfer_earnings(100), 100::bigint, 'transfer_earnings moves earnings into credits');
RESET ROLE;

SELECT throws_ok($$UPDATE payments.credits_ledger SET note = 'x'$$, 'P0001', 'credits_ledger is append-only', 'the credits ledger rejects updates');
SELECT throws_ok($$DELETE FROM payments.earnings_ledger$$, 'P0001', 'earnings_ledger is append-only', 'the earnings ledger rejects deletes');

SELECT * FROM finish();
ROLLBACK;
