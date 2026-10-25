BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(4);

CREATE FUNCTION pg_temp.signup(p_id uuid, p_name text) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_name || '@example.com',
          '{"provider":"discord"}', jsonb_build_object('full_name', p_name));
END;
$$;

CREATE FUNCTION pg_temp.invoice(p_user uuid, p_n int) RETURNS void LANGUAGE sql AS $$
  INSERT INTO payments.payments (user_id, provider, provider_id, credits, amount)
  VALUES (p_user, 'bitcart', 'inv-' || p_user || '-' || p_n, 5000000, 500);
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'one');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'two');

SELECT lives_ok($$SELECT pg_temp.invoice('00000000-0000-0000-0000-000000000001', n) FROM generate_series(1, 3) n$$,
  'three pending invoices are allowed');
SELECT throws_ok($$SELECT pg_temp.invoice('00000000-0000-0000-0000-000000000001', 4)$$, '23514',
  'too many pending payments', 'a fourth pending invoice is rejected');

UPDATE payments.payments SET status = 'expired'
WHERE id = (SELECT id FROM payments.payments WHERE user_id = '00000000-0000-0000-0000-000000000001' LIMIT 1);
SELECT lives_ok($$SELECT pg_temp.invoice('00000000-0000-0000-0000-000000000001', 5)$$,
  'an expired invoice frees up a slot');

SELECT lives_ok($$SELECT pg_temp.invoice('00000000-0000-0000-0000-000000000002', 1)$$,
  'the limit is per user');

SELECT * FROM finish();
ROLLBACK;
