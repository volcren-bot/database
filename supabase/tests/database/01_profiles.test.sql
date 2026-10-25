BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(19);

-- Helper: sign up a Discord user the way GoTrue does
CREATE FUNCTION pg_temp.signup(p_id uuid, p_meta jsonb, p_discord text DEFAULT NULL) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'real-' || p_id || '@example.com', '{"provider":"discord"}', p_meta);
  INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data, last_sign_in_at, created_at, updated_at)
  VALUES (gen_random_uuid(), p_id, 'discord', COALESCE(p_discord, 'd-' || p_id), jsonb_build_object('email', 'real@example.com', 'sub', p_id), now(), now(), now());
END;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-00000000000a', '{"full_name":"Alice","avatar_url":"https://cdn.discordapp.com/a.png"}', '111');
SELECT pg_temp.signup('00000000-0000-0000-0000-00000000000b', '{"full_name":"Bob"}', '222');
SELECT pg_temp.signup('00000000-0000-0000-0000-00000000000c', '{"full_name":"Mod"}', '333');
UPDATE profiles.profiles SET role = 'moderator' WHERE id = '00000000-0000-0000-0000-00000000000c';

-- sign-up pipeline
SELECT is((SELECT username FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-00000000000a'), 'Alice', 'sign-up creates the profile');
SELECT is((SELECT count(*)::int FROM payments.accounts WHERE user_id = '00000000-0000-0000-0000-00000000000a'), 1, 'sign-up creates the payment account');
SELECT is((SELECT email FROM auth.users WHERE id = '00000000-0000-0000-0000-00000000000a'), '00000000-0000-0000-0000-00000000000a@volcren.com', 'email is scrubbed on users');
SELECT ok((SELECT NOT identity_data ? 'email' FROM auth.identities WHERE user_id = '00000000-0000-0000-0000-00000000000a'), 'email is scrubbed on identities');

-- sign-ups with hostile Discord names still succeed
SELECT pg_temp.signup('00000000-0000-0000-0000-0000000000d1', jsonb_build_object('full_name', repeat('x', 100)));
SELECT is((SELECT char_length(username) FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-0000000000d1'), 32, '100-character name is cut to 32');
SELECT pg_temp.signup('00000000-0000-0000-0000-0000000000d2', '{"full_name":""}');
SELECT is((SELECT username FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-0000000000d2'), 'user-00000000', 'empty name falls back');
SELECT pg_temp.signup('00000000-0000-0000-0000-0000000000d3', jsonb_build_object('full_name', E'  a\n\tb  '));
SELECT is((SELECT username FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-0000000000d3'), 'ab', 'control characters and padding are removed');
SELECT pg_temp.signup('00000000-0000-0000-0000-0000000000d4', jsonb_build_object('full_name', 'x', 'avatar_url', 'http://insecure/a.png'));
SELECT is((SELECT avatar FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-0000000000d4'), '', 'a non-https avatar is stored as empty');

-- refresh_avatar mirrors the provider and survives bad values
UPDATE auth.users SET raw_user_meta_data = raw_user_meta_data || '{"avatar_url":"https://cdn.discordapp.com/new.png"}' WHERE id = '00000000-0000-0000-0000-00000000000a';
SELECT is((SELECT avatar FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-00000000000a'), 'https://cdn.discordapp.com/new.png', 'avatar follows the provider');
UPDATE auth.users SET raw_user_meta_data = raw_user_meta_data || '{"avatar_url":"javascript:x"}' WHERE id = '00000000-0000-0000-0000-00000000000a';
SELECT is((SELECT avatar FROM profiles.profiles WHERE id = '00000000-0000-0000-0000-00000000000a'), '', 'an invalid provider avatar is stored as empty');

-- only Discord
SELECT throws_ok(
  $$INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'x@example.com', '{"provider":"email"}')$$,
  '23514', 'only Discord sign-in is allowed', 'email provider is rejected');

-- username constraints (as postgres)
SELECT throws_ok($$UPDATE profiles.profiles SET username = 'a' WHERE id = '00000000-0000-0000-0000-00000000000b'$$, '23514', NULL, 'too short username is rejected');
SELECT throws_ok(format($$UPDATE profiles.profiles SET username = %L WHERE id = '00000000-0000-0000-0000-00000000000b'$$, repeat('x', 33)), '23514', NULL, 'too long username is rejected');
SELECT throws_ok($$UPDATE profiles.profiles SET username = ' padded ' WHERE id = '00000000-0000-0000-0000-00000000000b'$$, '23514', NULL, 'padded username is rejected');
SELECT throws_ok($$UPDATE profiles.profiles SET username = E'new\nline' WHERE id = '00000000-0000-0000-0000-00000000000b'$$, '23514', NULL, 'username with a newline is rejected');

-- client privileges
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
SELECT throws_ok($$UPDATE profiles.profiles SET avatar = 'https://x/y.png' WHERE id = '00000000-0000-0000-0000-00000000000b'$$, '42501', NULL, 'a client cannot change avatar');

-- provider IDs: own, other, moderator
SELECT is(profiles.get_provider_id('00000000-0000-0000-0000-00000000000b', 'discord'), '222', 'a user gets their own Discord ID');
SELECT is(profiles.get_provider_id('00000000-0000-0000-0000-00000000000a', 'discord'), NULL, 'a user gets NULL for another user');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000c","role":"authenticated"}', true);
SELECT is(profiles.get_provider_id('00000000-0000-0000-0000-00000000000a', 'discord'), '111', 'a moderator gets any Discord ID');

SELECT * FROM finish();
ROLLBACK;
