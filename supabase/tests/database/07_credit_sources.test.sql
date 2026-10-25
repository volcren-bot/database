BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(11);

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
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'mod', 'moderator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'user');

-- Manual adjustments ---------------------------------------------------------

SELECT is(payments.adjust_credits('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003', 250000, '  goodwill  '),
  250000::bigint, 'an administrator can grant credits');

SELECT results_eq(
  $$SELECT kind::text, amount, balance_after, note, granted_by FROM payments.credits_ledger WHERE user_id = '00000000-0000-0000-0000-000000000003'$$,
  $$VALUES ('adjustment', 250000::bigint, 250000::bigint, 'goodwill', '00000000-0000-0000-0000-000000000001'::uuid)$$,
  'the ledger records the kind, the trimmed note and who granted it');

SELECT is(payments.adjust_credits('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003', -50000, 'chargeback'),
  200000::bigint, 'an administrator can remove credits');

SELECT throws_ok($$SELECT payments.adjust_credits('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 1, 'nope')$$,
  '42501', 'only administrators can adjust credits', 'a moderator cannot adjust credits');
SELECT throws_ok($$SELECT payments.adjust_credits(NULL, '00000000-0000-0000-0000-000000000003', 1, 'nope')$$,
  '42501', 'only administrators can adjust credits', 'an adjustment needs an administrator');
SELECT throws_ok($$SELECT payments.adjust_credits('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003', 1, '  ')$$,
  'P0001', 'a note is required', 'an adjustment needs a note');
SELECT throws_ok($$SELECT payments.adjust_credits('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003', -999999, 'too much')$$,
  '23514', NULL, 'an adjustment cannot overdraw an account');

-- Top-ups with a bonus ---------------------------------------------------------

INSERT INTO payments.payments (id, user_id, provider, provider_id, credits, bonus, amount)
VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003', 'bitcart', 'inv-1', 1065051, 65051, 10000);
SELECT payments.settle_payment('10000000-0000-0000-0000-000000000001');

SELECT results_eq(
  $$SELECT kind::text, amount, payment_id, granted_by FROM payments.credits_ledger WHERE payment_id IS NOT NULL$$,
  $$VALUES ('topup', 1065051::bigint, '10000000-0000-0000-0000-000000000001'::uuid, NULL::uuid)$$,
  'a top-up credits the bonus too, links to its payment and has no granter');

SELECT throws_ok($$INSERT INTO payments.payments (user_id, provider, provider_id, credits, bonus, amount)
  VALUES ('00000000-0000-0000-0000-000000000003', 'bitcart', 'inv-2', 1000, 1000, 100)$$,
  '23514', NULL, 'the bonus is part of the credits, not all of them');

-- Privileges --------------------------------------------------------------------

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT payments.adjust_credits('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003', 1, 'self-service')$$,
  '42501', NULL, 'clients cannot call adjust_credits');
SELECT throws_ok($$SELECT payments.post_credits('00000000-0000-0000-0000-000000000003', 'adjustment', 1)$$,
  '42501', NULL, 'clients cannot call post_credits');

SELECT * FROM finish();
ROLLBACK;
