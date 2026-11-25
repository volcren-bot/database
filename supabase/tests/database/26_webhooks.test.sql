BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(57);

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

CREATE FUNCTION pg_temp.as_service() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
END;
$$;

CREATE FUNCTION pg_temp.save(p_id uuid, p_url text, p_events webhooks.event[], p_bearer text, p_headers jsonb) RETURNS uuid LANGUAGE sql AS $$
  SELECT webhooks.save_endpoint(p_id, 'CI', p_url, 'text', p_events, true, p_bearer, p_headers);
$$;

CREATE FUNCTION pg_temp.pending(p_endpoint uuid, p_event webhooks.event) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM webhooks.deliveries WHERE endpoint_id = p_endpoint AND event = p_event AND status = 'pending';
$$;

CREATE FUNCTION pg_temp.endpoint(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM webhooks.endpoints WHERE name = p_name;
$$;

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'player');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'contrib', 'contributor');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'banned', 'contributor');

SELECT scripts.register_injector('2026.11.15-aaaaaaa', 100);

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{client_release}', NULL, '[]')$$, '42501', NULL, 'a user cannot add a webhook');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000003');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'http://hooks.example.com/x', '{client_release}', NULL, '[]')$$, '23514', NULL, 'webhooks are https');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://10.0.0.1/x', '{client_release}', NULL, '[]')$$, '23514', NULL, 'to a host name, not an address');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://user:pw@hooks.example.com/x', '{client_release}', NULL, '[]')$$, '23514', NULL, 'without credentials in the url');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{}', NULL, '[]')$$, '23514', NULL, 'with at least one event');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{ping}', NULL, '[]')$$, '23514', NULL, 'and pings are not an event to subscribe to');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{client_release}', NULL, '[{"name": "Host", "value": "internal"}]')$$, '23514', NULL, 'reserved headers are refused');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{client_release}', NULL, '[{"name": "X-Volcren-Signature", "value": "x"}]')$$, '23514', NULL, 'and so are ours');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{client_release}', NULL, '[{"name": "X-A", "value": "a\r\nX-B: b"}]')$$, '23514', NULL, 'a header value cannot break the line');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{client_release}', NULL, '[{"name": "X-A", "value": "1"}, {"name": "x-a", "value": "2"}]')$$, '23514', NULL, 'nor repeat a name');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{client_release}', NULL, (SELECT jsonb_agg(jsonb_build_object('name', 'X-' || i, 'value', 'v')) FROM generate_series(1, 9) i))$$, '23514', NULL, 'at most 8 headers');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{client_release}', 'has space', '[]')$$, '23514', NULL, 'a bearer token is one printable word');
SELECT throws_ok($$SELECT pg_temp.save(NULL, 'https://hooks.example.com/x', '{client_release}', NULL, '[{"name": "X-A", "value": null}]')$$, '22023', NULL, 'a new header needs a value');

SELECT lives_ok($$SELECT webhooks.save_endpoint(NULL, 'Release', 'https://api.example.com/v1/fire', 'text', '{client_release, client_release}', true, 'tok3n', '[{"name": "anthropic-version", "value": "2023-06-01"}]')$$, 'a contributor adds a webhook');
SELECT is((SELECT events FROM webhooks.endpoints WHERE name = 'Release'), '{client_release}'::webhooks.event[], 'events are kept once each');
SELECT results_eq($$SELECT has_bearer, header_names, char_length(signing_secret) FROM webhooks.endpoints WHERE name = 'Release'$$,
  $$VALUES (true, '{anthropic-version}'::text[], 64)$$, 'the owner sees that a token is set, the header names and the signing secret');
SELECT throws_ok($$SELECT bearer_token FROM webhooks.endpoints$$, '42501', NULL, 'but never the token');
SELECT throws_ok($$SELECT header_values FROM webhooks.endpoints$$, '42501', NULL, 'nor the header values');
SELECT throws_ok($$UPDATE webhooks.endpoints SET url = 'https://other.example.com'$$, '42501', NULL, 'changes go through save_endpoint');
SELECT throws_ok($$INSERT INTO webhooks.endpoints (user_id, name, url, events) VALUES (profiles.uid(), 'x', 'https://a.example.com', '{client_release}')$$, '42501', NULL, 'and so do new webhooks');

SELECT lives_ok($$SELECT pg_temp.save(pg_temp.endpoint('Release'), 'https://api.example.com/v1/fire', '{client_release, script_check}', NULL, '[{"name": "anthropic-version", "value": null}, {"name": "X-Extra", "value": "1"}]')$$, 'editing without the secrets keeps them');
RESET ROLE;
SELECT results_eq($$SELECT name, bearer_token, header_names, header_values FROM webhooks.endpoints WHERE id = pg_temp.endpoint('CI')$$,
  $$VALUES ('CI', 'tok3n', '{anthropic-version, X-Extra}'::text[], '{2023-06-01, 1}'::text[])$$, 'the token and the kept header value are unchanged');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT pg_temp.save(pg_temp.endpoint('CI'), 'https://api.example.com/v1/fire', '{client_release, script_check}', '', '[]')$$, 'an empty token clears it');
SELECT is((SELECT has_bearer FROM webhooks.endpoints WHERE name = 'CI'), false, 'so none is sent');
SELECT webhooks.save_endpoint(NULL, 'Scripts only', 'https://b.example.com', 'volcren', '{script_check}', true, NULL, '[]');
SELECT webhooks.save_endpoint(NULL, 'Off', 'https://c.example.com', 'volcren', '{client_release}', false, NULL, '[]');
SELECT webhooks.save_endpoint(NULL, 'Four', 'https://d.example.com', 'volcren', '{client_release}', false, NULL, '[]');
SELECT webhooks.save_endpoint(NULL, 'Five', 'https://e.example.com', 'volcren', '{client_release}', false, NULL, '[]');
SELECT throws_ok($$SELECT webhooks.save_endpoint(NULL, 'Six', 'https://f.example.com', 'volcren', '{client_release}', true, NULL, '[]')$$, '54000', NULL, 'at most 5 webhooks per account');
SELECT throws_ok($$SELECT webhooks.enqueue('client_release', '{}')$$, '42501', NULL, 'clients cannot enqueue');
SELECT throws_ok($$SELECT * FROM webhooks.claim_deliveries(10)$$, '42501', NULL, 'nor claim deliveries');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
SELECT webhooks.save_endpoint(NULL, 'Banned', 'https://g.example.com', 'volcren', '{client_release}', true, NULL, '[]');
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT webhooks.save_endpoint(NULL, 'Author', 'https://h.example.com', 'github_dispatch', '{client_release, script_check}', true, NULL, '[]');
SELECT is((SELECT count(*) FROM webhooks.endpoints), 1::bigint, 'nobody sees another account''s webhooks');
SELECT throws_ok($$SELECT webhooks.rotate_signing_secret(pg_temp.endpoint('CI'))$$, 'P0002', NULL, 'nor rotates their secret');
RESET ROLE;
UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000004';

SELECT scripts.register_injector('2026.11.16-bbbbbbb', 200);
SELECT is(pg_temp.pending(pg_temp.endpoint('CI'), 'client_release'), 1::bigint, 'a new release is queued for subscribers');
SELECT is((SELECT payload ->> 'version' FROM webhooks.deliveries WHERE endpoint_id = pg_temp.endpoint('CI')), '2026.11.16-bbbbbbb', 'with its version');
SELECT is(pg_temp.pending(pg_temp.endpoint('Scripts only'), 'client_release'), 0::bigint, 'not for webhooks without the event');
SELECT is(pg_temp.pending(pg_temp.endpoint('Off'), 'client_release'), 0::bigint, 'nor turned off ones');
SELECT is(pg_temp.pending(pg_temp.endpoint('Banned'), 'client_release'), 0::bigint, 'nor a banned owner''s');
SELECT scripts.register_injector('2026.11.16-bbbbbbb', 200);
SELECT is(pg_temp.pending(pg_temp.endpoint('CI'), 'client_release'), 1::bigint, 'registering a known release queues nothing');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
INSERT INTO scripts.scripts (id, title, description, content, published) VALUES ('10000000-0000-0000-0000-000000000001', 'Bosses', 'd', 'c', true);
INSERT INTO scripts.versions (id, files) VALUES ('10000000-0000-0000-0000-000000000001', ARRAY['main.luau']);
INSERT INTO storage.objects (bucket_id, name) VALUES ('scripts', '10000000-0000-0000-0000-000000000001/000000001/main.luau');
INSERT INTO scripts.version_keys (id, revision, key) VALUES ('10000000-0000-0000-0000-000000000001', 1, decode(repeat('ab', 32), 'hex'));
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.15-aaaaaaa', NULL);
SELECT is((SELECT count(*) FROM webhooks.deliveries WHERE event = 'script_check'), 0::bigint, 'the check of a pending upload is not sent');
SET LOCAL ROLE authenticated;
SELECT scripts.publish_version('10000000-0000-0000-0000-000000000001', 1);
RESET ROLE;
SELECT scripts.record_check('10000000-0000-0000-0000-000000000001', 1, '2026.11.16-bbbbbbb',
  (SELECT jsonb_agg(jsonb_build_object('file', 'main.luau', 'line', i, 'column', 1, 'message', 'bad')) FROM generate_series(1, 12) i));
SELECT results_eq($$SELECT payload ->> 'passed', payload ->> 'injector', payload ->> 'problem_count', jsonb_array_length(payload -> 'problems') FROM webhooks.deliveries WHERE event = 'script_check' AND endpoint_id = pg_temp.endpoint('Author')$$,
  $$VALUES ('false', '2026.11.15-aaaaaaa', '12', 10)$$, 'a failed check of a live revision is sent to its author, with the first 10 problems and the pin it stays on');
SELECT is((SELECT count(*) FROM webhooks.deliveries WHERE event = 'script_check' AND endpoint_id <> pg_temp.endpoint('Author')), 0::bigint, 'and to nobody else');

SET LOCAL ROLE service_role;
SELECT pg_temp.as_service();
SELECT results_eq($$SELECT url, bearer_token, header_names, attempts FROM webhooks.claim_deliveries(10) WHERE event = 'client_release' AND url LIKE 'https://api.%'$$,
  $$VALUES ('https://api.example.com/v1/fire', NULL::text, '{}'::text[], 1::smallint)$$, 'the api claims due deliveries with what it needs to send them');
SELECT is((SELECT count(*) FROM webhooks.claim_deliveries(10)), 0::bigint, 'a claimed delivery is not claimed again while it is being sent');

SELECT webhooks.finish_delivery((SELECT id FROM webhooks.deliveries WHERE endpoint_id = pg_temp.endpoint('CI')), 503, NULL, true);
SELECT results_eq($$SELECT status::text, response_status, error, next_attempt_at > now() + interval '50 seconds' FROM webhooks.deliveries WHERE endpoint_id = pg_temp.endpoint('CI')$$,
  $$VALUES ('pending', 503::smallint, 'The endpoint answered 503', true)$$, 'a retryable failure is tried again later');
SELECT is((SELECT failures FROM webhooks.endpoints WHERE name = 'CI'), 1, 'and counts against the webhook');
SELECT webhooks.finish_delivery((SELECT id FROM webhooks.deliveries WHERE endpoint_id = pg_temp.endpoint('CI')), 204, NULL, false);
SELECT results_eq($$SELECT d.status::text, e.failures FROM webhooks.deliveries d JOIN webhooks.endpoints e ON e.id = d.endpoint_id WHERE e.name = 'CI'$$,
  $$VALUES ('delivered', 0)$$, 'a success delivers it and clears the count');

SELECT webhooks.finish_delivery((SELECT id FROM webhooks.deliveries WHERE event = 'script_check'), 404, NULL, false);
SELECT is((SELECT status::text FROM webhooks.deliveries WHERE event = 'script_check'), 'failed', 'a failure that is not worth retrying fails at once');

UPDATE webhooks.endpoints SET failures = 14 WHERE name = 'Author';
SELECT webhooks.finish_delivery((SELECT id FROM webhooks.deliveries WHERE endpoint_id = pg_temp.endpoint('Author') AND event = 'client_release'), NULL, 'timed out', true);
SELECT results_eq($$SELECT enabled, disabled_reason IS NOT NULL FROM webhooks.endpoints WHERE name = 'Author'$$,
  $$VALUES (false, true)$$, 'the 15th failure in a row turns the webhook off');
UPDATE webhooks.deliveries SET next_attempt_at = now() WHERE endpoint_id = pg_temp.endpoint('Author');
SELECT is((SELECT count(*) FROM webhooks.claim_deliveries(10)), 0::bigint, 'its retries are not sent');
SELECT is((SELECT status::text FROM webhooks.deliveries WHERE endpoint_id = pg_temp.endpoint('Author') AND event = 'client_release'), 'failed', 'they fail instead');
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SELECT lives_ok($$SELECT webhooks.send_test(pg_temp.endpoint('Author'))$$, 'the owner can test a webhook that is off');
SELECT throws_ok($$SELECT webhooks.send_test(pg_temp.endpoint('Author'))$$, '54000', NULL, 'one test at a time');
SELECT is((SELECT count(*) FROM webhooks.deliveries), 3::bigint, 'the owner reads their deliveries');
SELECT lives_ok($$SELECT webhooks.save_endpoint(pg_temp.endpoint('Author'), 'Author', 'https://h.example.com', 'github_dispatch', '{client_release}', true, NULL, '[]')$$, 'turning it back on');
SELECT results_eq($$SELECT enabled, failures, disabled_reason FROM webhooks.endpoints$$, $$VALUES (true, 0, NULL::text)$$, 'clears the failures');
SELECT isnt(webhooks.rotate_signing_secret(pg_temp.endpoint('Author')), (SELECT signing_secret FROM webhooks.endpoints), 'rotating hands back a new secret');

SELECT pg_temp.act('00000000-0000-0000-0000-000000000003');
SELECT is((SELECT count(*) FROM webhooks.deliveries), 1::bigint, 'and nobody else''s');
SELECT throws_ok($$SELECT webhooks.send_test(pg_temp.endpoint('Author'))$$, 'P0002', NULL, 'nor tests them');
DELETE FROM webhooks.endpoints WHERE name = 'Off';
SELECT is((SELECT count(*) FROM webhooks.endpoints), 4::bigint, 'the owner deletes a webhook');
RESET ROLE;

UPDATE webhooks.deliveries SET finished_at = now() - interval '31 days' WHERE status <> 'pending';
SELECT is(webhooks.delete_old_deliveries(), 3, 'finished deliveries are kept for 30 days');

SELECT * FROM finish();
ROLLBACK;
