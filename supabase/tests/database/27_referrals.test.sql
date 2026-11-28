BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(40);

CREATE FUNCTION pg_temp.signup(p_id uuid, p_name text, p_discord_age interval, p_discord_n integer) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_name || '@example.com',
          '{"provider":"discord"}', jsonb_build_object('full_name', p_name));
  INSERT INTO auth.identities (provider_id, user_id, identity_data, provider)
  VALUES (((((extract(epoch FROM now() - p_discord_age) * 1000)::bigint - 1420070400000) << 22) | p_discord_n)::text,
          p_id, '{}'::jsonb, 'discord');
END;
$$;

CREATE FUNCTION pg_temp.code(p_user uuid) RETURNS text LANGUAGE sql AS $$
  SELECT referral_code FROM profiles.profiles WHERE id = p_user;
$$;

CREATE FUNCTION pg_temp.claim(p_user uuid, p_code text) RETURNS text
    LANGUAGE plpgsql AS $$
DECLARE
  v_status text;
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_status := payments.claim_referral(p_code);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v_status;
END;
$$;

CREATE FUNCTION pg_temp.ran(p_user uuid, p_script uuid, p_minutes integer, p_days_ago integer, p_author uuid DEFAULT '00000000-0000-0000-0000-000000000001') RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO payments.sessions (user_id, script_id, author_id, revision, price, charged_minutes, started_at)
  VALUES (p_user, p_script, p_author, 1, 0, p_minutes, now() - make_interval(days => p_days_ago))
  RETURNING id INTO v_id;
  UPDATE payments.sessions SET ended_at = now(), end_reason = 'stopped' WHERE id = v_id;
END;
$$;

CREATE FUNCTION pg_temp.qualify(p_user uuid, p_script uuid) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.ran(p_user, p_script, 100, 1);
  SELECT pg_temp.ran(p_user, p_script, 20, 0);
$$;

CREATE FUNCTION pg_temp.topup(p_user uuid, p_ref text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO payments.payments (id, user_id, provider, provider_id, microcredits, amount)
  VALUES (md5(p_ref)::uuid, p_user, 'bitcart', p_ref, 1000000, 100);
  SELECT payments.settle_payment(md5(p_ref)::uuid);
$$;

CREATE FUNCTION pg_temp.credits(p_user uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT microcredits FROM payments.accounts WHERE user_id = p_user;
$$;

CREATE FUNCTION pg_temp.referral(p_invitee uuid) RETURNS payments.referrals LANGUAGE sql AS $$
  SELECT * FROM payments.referrals WHERE invitee = p_invitee;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', '1 year', 1);
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'alice', '1 year', 2);
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'bob', '1 year', 3);
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'carol', '1 year', 4);
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000005', 'young', '5 days', 5);
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000006', 'dave', '1 year', 6);
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000007', 'frank', '1 year', 7);
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000008', 'leaver', '1 year', 8);

SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000003', pg_temp.code('00000000-0000-0000-0000-000000000002')), 'unavailable',
  'a claim is refused while the vault has no REFERRAL_SECRET');

SELECT vault.create_secret('referral test secret', 'REFERRAL_SECRET');

SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000002', pg_temp.code('00000000-0000-0000-0000-000000000002')), 'own',
  'nobody refers themselves');
SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000003', 'nope'), 'invalid', 'an unknown code is invalid');
SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000003', ' ' || upper(pg_temp.code('00000000-0000-0000-0000-000000000002')) || ' '), 'claimed',
  'a code is matched without case or padding');
SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000003', pg_temp.code('00000000-0000-0000-0000-000000000004')), 'already_referred',
  'an account is referred once');
SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000002', pg_temp.code('00000000-0000-0000-0000-000000000003')), 'own',
  'nobody is referred by their own invitee');

SELECT pg_temp.ran('00000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000001', 1, 0);
SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000006', pg_temp.code('00000000-0000-0000-0000-000000000002')), 'not_new',
  'an account that already ran a script cannot be referred');

SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000005', pg_temp.code('00000000-0000-0000-0000-000000000002')), 'claimed',
  'a young Discord account can still be referred');
SELECT is((pg_temp.referral('00000000-0000-0000-0000-000000000005')).eligible, false, 'but its referral earns nothing');
SELECT is((pg_temp.referral('00000000-0000-0000-0000-000000000003')).eligible, true, 'an old Discord account is eligible');

SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000008', pg_temp.code('00000000-0000-0000-0000-000000000002')), 'claimed', 'leaver is referred');
DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000008';
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000009', 'leaver again', '1 year', 8);
SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000009', pg_temp.code('00000000-0000-0000-0000-000000000002')), 'already_referred',
  'a deleted account that signs up again with the same Discord account cannot be referred again');

SELECT pg_temp.ran('00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 130, 0);
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000002'), 0::bigint, 'runtime on a single day earns nothing');

SELECT pg_temp.ran('00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 1, 1);
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000002'), 250000::bigint, 'two hours of a script over two days earns 0.25');
SELECT is((SELECT bonus_microcredits FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-000000000002'), 250000::bigint,
  'referral rewards are bonus credits');
SELECT is((SELECT kind FROM payments.credits_ledger WHERE user_id = '00000000-0000-0000-0000-000000000002' ORDER BY id DESC LIMIT 1),
  'referral'::payments.credit_kind, 'the ledger records a referral');

SELECT pg_temp.ran('00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 500, 2);
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000002'), 250000::bigint, 'each script counts once');

SELECT pg_temp.ran('00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000009', 200, 1, '00000000-0000-0000-0000-000000000003');
SELECT pg_temp.ran('00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000009', 1, 0, '00000000-0000-0000-0000-000000000003');
SELECT is(cardinality((pg_temp.referral('00000000-0000-0000-0000-000000000003')).runtime_scripts), 1, 'scripts the invitee wrote do not count');

SELECT pg_temp.qualify('00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002');
SELECT pg_temp.qualify('00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000003');
SELECT pg_temp.qualify('00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000004');
SELECT pg_temp.qualify('00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000005');
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000002'), 1000000::bigint, 'runtime earns at most 4 x 0.25');
SELECT is(cardinality((pg_temp.referral('00000000-0000-0000-0000-000000000003')).runtime_scripts), 4, 'four scripts are recorded');

SELECT pg_temp.topup('00000000-0000-0000-0000-000000000003', 'bob-1');
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000002'), 2000000::bigint, 'the first top-up earns 1');
SELECT pg_temp.topup('00000000-0000-0000-0000-000000000003', 'bob-2');
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000002'), 2000000::bigint, 'later top-ups earn nothing more');

SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000004', pg_temp.code('00000000-0000-0000-0000-000000000003')), 'claimed', 'carol is referred by bob');
SELECT pg_temp.qualify('00000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001');
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000003') - 1000000 - 1000000, 250000::bigint, 'bob earns from carol''s runtime');
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000002'), 2100000::bigint, 'alice earns 0.1 when her invitee''s invitee qualifies');
SELECT pg_temp.topup('00000000-0000-0000-0000-000000000004', 'carol-1');
SELECT is(pg_temp.credits('00000000-0000-0000-0000-000000000002'), 2100000::bigint, 'an invitee''s invitee counts once');
SELECT is((pg_temp.referral('00000000-0000-0000-0000-000000000003')).earned, 2100000::bigint, 'the referral records what it earned');

SELECT pg_temp.qualify('00000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000001');
SELECT pg_temp.topup('00000000-0000-0000-0000-000000000005', 'young-1');
SELECT is((pg_temp.referral('00000000-0000-0000-0000-000000000005')).earned, 0::bigint, 'a young Discord account earns its referrer nothing');

SELECT is(pg_temp.claim('00000000-0000-0000-0000-000000000007', pg_temp.code('00000000-0000-0000-0000-000000000002')), 'claimed', 'frank is referred');
UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000007';
SELECT pg_temp.qualify('00000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000001');
SELECT is((pg_temp.referral('00000000-0000-0000-0000-000000000007')).earned, 0::bigint, 'nothing is paid while the invitee is banned');
UPDATE profiles.profiles SET banned_at = NULL WHERE id = '00000000-0000-0000-0000-000000000007';
SELECT pg_temp.ran('00000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000001', 1, 0);
SELECT is((pg_temp.referral('00000000-0000-0000-0000-000000000007')).earned, 250000::bigint, 'progress is paid at the next session after an unban');

SELECT is(payments.grant_referral_gift('00000000-0000-0000-0000-000000000004'), 500000::bigint, 'the invitee gets the sign-up gift');
SELECT is(payments.grant_referral_gift('00000000-0000-0000-0000-000000000004'), 0::bigint, 'once');
SELECT is(payments.grant_referral_gift('00000000-0000-0000-0000-000000000005'), 0::bigint, 'not for a young Discord account');
SELECT is(payments.grant_referral_gift('00000000-0000-0000-0000-000000000002'), 0::bigint, 'not without a referral');

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', '00000000-0000-0000-0000-000000000002', 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM payments.list_referrals()), 4::bigint, 'the referrer lists their referrals, deleted invitees included');
SELECT results_eq($$SELECT runtime_scripts, invites, topped_up, earned FROM payments.list_referrals() WHERE eligible ORDER BY earned DESC LIMIT 1$$,
  $$VALUES (4, 1, true, 2100000::bigint)$$, 'with their progress');
SELECT throws_ok($$SELECT * FROM payments.referrals$$, '42501', NULL, 'clients cannot read the referrals table');
SELECT throws_ok($$SELECT payments.grant_referral_gift('00000000-0000-0000-0000-000000000004')$$, '42501', NULL, 'clients cannot grant gifts');
RESET ROLE;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', '00000000-0000-0000-0000-000000000004', 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
SELECT results_eq($$SELECT eligible, gift_at IS NOT NULL FROM payments.own_referral()$$, $$VALUES (true, true)$$,
  'an invitee sees their own referral and gift');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
