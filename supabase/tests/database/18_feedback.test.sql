BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(65);

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

SELECT pg_temp.signup('00000000-0000-0000-0000-000000000001', 'author', 'scripter');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000002', 'tester', 'tester');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000003', 'mod', 'moderator');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000004', 'runner');
SELECT pg_temp.signup('00000000-0000-0000-0000-000000000005', 'stranger');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001');
SELECT pg_temp.make_script('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001');

-- the runner's extra instances need a credit of balance for the fee
SELECT payments.post_credits('00000000-0000-0000-0000-000000000004', 'adjustment', 100);
SELECT payments.post_credits('00000000-0000-0000-0000-000000000005', 'adjustment', 100);
CREATE TEMP TABLE s (name text PRIMARY KEY, id uuid);
INSERT INTO s SELECT 'open', session_id FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
INSERT INTO s SELECT 'ended', session_id FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
INSERT INTO s SELECT 'old', session_id FROM payments.start_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002');
INSERT INTO s SELECT 'other', session_id FROM payments.start_session('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
SELECT payments.end_session((SELECT id FROM s WHERE name = 'ended'), 'stopped');
SELECT payments.end_session((SELECT id FROM s WHERE name = 'old'), 'stopped');
UPDATE payments.sessions SET started_at = now() - interval '26 hours', ended_at = now() - interval '25 hours' WHERE id = (SELECT id FROM s WHERE name = 'old');

-- recent sessions (service_role)
SELECT set_eq(
  $$SELECT session_id, score, reports FROM feedback.recent_sessions('00000000-0000-0000-0000-000000000004')$$,
  $$SELECT id, NULL::smallint, 0 FROM s WHERE name IN ('open', 'ended')$$,
  'recent_sessions lists the open and the just ended session, not the one from yesterday or another account''s'
);
SELECT is((SELECT title FROM feedback.recent_sessions('00000000-0000-0000-0000-000000000004') LIMIT 1), 'S 10000000-0000-0000-0000-000000000001', 'with the script title');

-- scoring
SELECT lives_ok($$SELECT feedback.score_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), 7)$$, 'a running session can be scored');
SELECT is((SELECT score FROM feedback.scores WHERE user_id = '00000000-0000-0000-0000-000000000004'), 7::smallint, 'the score is stored');
SELECT lives_ok($$SELECT feedback.score_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'ended'), 9)$$, 'an ended session within 24 hours can be scored');
SELECT is((SELECT count(*) FROM feedback.scores WHERE user_id = '00000000-0000-0000-0000-000000000004'), 1::bigint, 'scoring the same script again keeps one row');
SELECT is((SELECT (score, session_id) FROM feedback.scores WHERE user_id = '00000000-0000-0000-0000-000000000004'), ((9::smallint, (SELECT id FROM s WHERE name = 'ended'))), 'with the new score and session');
SELECT is((SELECT score FROM feedback.recent_sessions('00000000-0000-0000-0000-000000000004') WHERE session_id = (SELECT id FROM s WHERE name = 'open')), 9::smallint, 'recent_sessions shows the script''s score on every session of it');
SELECT throws_ok($$SELECT feedback.score_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), 11)$$, '23514', 'score must be 1 to 10', 'a score above 10 is refused');
SELECT throws_ok($$SELECT feedback.score_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), 0)$$, '23514', 'score must be 1 to 10', 'a score below 1 is refused');
SELECT throws_ok($$SELECT feedback.score_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'other'), 5)$$, 'P0002', 'session not found', 'another account''s session looks like a missing one');
SELECT throws_ok($$SELECT feedback.score_session('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000dead', 5)$$, 'P0002', 'session not found', 'an unknown session is not found');
SELECT throws_ok($$SELECT feedback.score_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'old'), 5)$$, '22023', 'session too old', 'a session that ended over 24 hours ago cannot be scored');

-- reporting
CREATE TEMP TABLE r (name text PRIMARY KEY, id uuid);
INSERT INTO r SELECT 'first', feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), '  it clicked the wrong tree  ', 'line 1' || E'\n' || 'line 2', '{"position": {"x": 1, "y": 2}}', '{"loader": "2026.11.04-abcdef0"}');
SELECT is((SELECT description FROM feedback.reports WHERE id = (SELECT id FROM r WHERE name = 'first')), 'it clicked the wrong tree', 'the description is stored trimmed');
SELECT is((SELECT (script_id, user_id, revision, status::text, assigned_to) FROM feedback.reports WHERE id = (SELECT id FROM r WHERE name = 'first')),
  (('10000000-0000-0000-0000-000000000001'::uuid, '00000000-0000-0000-0000-000000000004'::uuid, 1, 'open'::text, NULL::uuid)), 'the report takes its script and revision from the session and starts open');
SELECT is((SELECT reports FROM feedback.recent_sessions('00000000-0000-0000-0000-000000000004') WHERE session_id = (SELECT id FROM s WHERE name = 'open')), 1, 'recent_sessions counts the session''s reports');
SELECT throws_ok($$SELECT feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'other'), 'x', NULL, NULL, NULL)$$, 'P0002', 'session not found', 'a report on another account''s session is refused');
SELECT throws_ok($$SELECT feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'old'), 'x', NULL, NULL, NULL)$$, '22023', 'session too old', 'a report on yesterday''s session is refused');
SELECT throws_ok($$SELECT feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), repeat('x', 2001), NULL, NULL, NULL)$$, '23514', NULL, 'a description over 2000 characters is refused');
SELECT throws_ok($$SELECT feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), 'x', repeat('x', 262145), NULL, NULL)$$, '23514', NULL, 'a log over 256 KiB is refused');
SELECT lives_ok($$SELECT feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'ended'), '', NULL, NULL, NULL) FROM generate_series(1, 4)$$, 'up to 5 reports an hour are accepted');
SELECT throws_ok($$SELECT feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), 'x', NULL, NULL, NULL)$$, '54000', 'too many reports', 'the sixth report in an hour is refused');
UPDATE feedback.reports SET created_at = now() - interval '2 hours' WHERE description = '';
SELECT lives_ok($$SELECT feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), 'x', NULL, NULL, NULL)$$, 'older reports do not count against the limit');
DELETE FROM feedback.reports WHERE id <> (SELECT id FROM r WHERE name = 'first');
UPDATE profiles.profiles SET banned_at = now() WHERE id = '00000000-0000-0000-0000-000000000005';
SELECT throws_ok($$SELECT feedback.report_session('00000000-0000-0000-0000-000000000005', (SELECT id FROM s WHERE name = 'other'), 'x', NULL, NULL, NULL)$$, '42501', 'account banned', 'a banned account cannot report');
SELECT throws_ok($$SELECT feedback.score_session('00000000-0000-0000-0000-000000000005', (SELECT id FROM s WHERE name = 'other'), 5)$$, '42501', 'account banned', 'or score');
UPDATE profiles.profiles SET banned_at = NULL WHERE id = '00000000-0000-0000-0000-000000000005';

-- anonymous visitors see nothing
SET LOCAL ROLE anon;
SELECT throws_ok('SELECT * FROM feedback.reports', '42501', NULL, 'anonymous visitors cannot read reports');
SELECT throws_ok('SELECT * FROM feedback.scores', '42501', NULL, 'anonymous visitors cannot read scores');
SELECT throws_ok($$SELECT * FROM feedback.list_reports()$$, '42501', NULL, 'nor list them');
SELECT pg_temp.service();

-- the reporter sees their own rows
SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM feedback.reports), 1::bigint, 'the reporter sees their report');
SELECT is((SELECT log FROM feedback.reports), 'line 1' || E'\n' || 'line 2', 'with its log');
SELECT is((SELECT count(*) FROM feedback.scores), 1::bigint, 'and their own score');
SELECT throws_ok($$SELECT * FROM feedback.score_summary('10000000-0000-0000-0000-000000000001')$$, '42501', 'not allowed', 'but not the script''s score summary');
UPDATE feedback.reports SET status = 'resolved';
SELECT is((SELECT status::text FROM feedback.reports), 'open', 'and cannot change its status');
SELECT is((SELECT count(*) FROM feedback.list_testers()), 0::bigint, 'nor list testers');
SELECT pg_temp.service();

-- a stranger sees nothing
SELECT pg_temp.act('00000000-0000-0000-0000-000000000005');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM feedback.reports), 0::bigint, 'another user sees no reports');
SELECT is((SELECT count(*) FROM feedback.scores), 0::bigint, 'and no scores');
SELECT is((SELECT count(*) FROM feedback.list_reports()), 0::bigint, 'list_reports is empty for them');
DELETE FROM feedback.reports;
SELECT pg_temp.service();
SELECT is((SELECT count(*) FROM feedback.reports), 1::bigint, 'and their delete removed nothing');

-- the author sees aggregates and full reports with usernames
UPDATE feedback.reports SET created_at = created_at - interval '1 minute', updated_at = updated_at - interval '1 minute';
SELECT pg_temp.act('00000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT results_eq($$SELECT count, average, histogram FROM feedback.score_summary('10000000-0000-0000-0000-000000000001')$$,
  $$VALUES (1, 9.00::numeric, ARRAY[0, 0, 0, 0, 0, 0, 0, 0, 1, 0])$$, 'the author gets count, average and histogram');
SELECT results_eq($$SELECT count, average, histogram FROM feedback.score_summary('10000000-0000-0000-0000-000000000002')$$,
  $$VALUES (0, NULL::numeric, ARRAY[0, 0, 0, 0, 0, 0, 0, 0, 0, 0])$$, 'an unscored script has a zero summary');
SELECT is((SELECT count(*) FROM feedback.scores), 0::bigint, 'but no individual scores');
SELECT results_eq($$SELECT username, script_url, has_log, has_snapshot, has_diagnostics, assignee FROM feedback.list_reports()$$,
  $$VALUES ('runner', (SELECT url FROM scripts.scripts WHERE id = '10000000-0000-0000-0000-000000000001'), true, true, true, NULL::text)$$, 'list_reports names the reporter and says which attachments exist');
SELECT is((SELECT count(*) FROM feedback.list_reports('10000000-0000-0000-0000-000000000002')), 0::bigint, 'and filters by script');
SELECT is((SELECT snapshot FROM feedback.reports), '{"position": {"x": 1, "y": 2}}'::jsonb, 'the author reads the attachments from the table');
SELECT results_eq($$SELECT username FROM feedback.list_testers()$$, $$VALUES ('author'), ('mod'), ('tester')$$, 'the author can pick among tester+ accounts');
SELECT throws_ok($$UPDATE feedback.reports SET description = 'edited'$$, '42501', NULL, 'the description cannot be edited');
SELECT throws_ok($$UPDATE feedback.reports SET assigned_to = '00000000-0000-0000-0000-000000000005'$$, '23514', 'reports can only be assigned to testers', 'a plain user cannot be assigned');
SELECT lives_ok($$UPDATE feedback.reports SET assigned_to = '00000000-0000-0000-0000-000000000002', status = 'in_progress'$$, 'the author assigns a tester and changes the status');
SELECT pg_temp.service();
SELECT is((SELECT (status::text, assigned_to) FROM feedback.reports), (('in_progress'::text, '00000000-0000-0000-0000-000000000002'::uuid)), 'and both are stored');
SELECT ok((SELECT updated_at > created_at FROM feedback.reports), 'updated_at moved');

-- the assigned tester works the report but cannot pass it on
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM feedback.list_reports()), 1::bigint, 'the assigned tester sees the report');
SELECT is((SELECT assignee FROM feedback.list_reports()), 'tester', 'with themselves as assignee');
SELECT lives_ok($$UPDATE feedback.reports SET status = 'resolved'$$, 'and can change its status');
SELECT throws_ok($$UPDATE feedback.reports SET assigned_to = '00000000-0000-0000-0000-000000000003'$$, '42501', 'only the author or a moderator can assign a report', 'but not reassign it');
SELECT is((SELECT count(*) FROM feedback.list_testers()), 0::bigint, 'a tester without scripts gets no tester list');
SELECT pg_temp.service();
UPDATE feedback.reports SET assigned_to = NULL;
SELECT pg_temp.act('00000000-0000-0000-0000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM feedback.reports), 0::bigint, 'once unassigned the tester sees nothing');
SELECT pg_temp.service();

-- moderators see everything
SELECT pg_temp.act('00000000-0000-0000-0000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM feedback.scores), 1::bigint, 'a moderator sees individual scores');
SELECT is((SELECT count(*) FROM feedback.list_reports()), 1::bigint, 'and every report');
SELECT lives_ok($$SELECT feedback.score_summary('10000000-0000-0000-0000-000000000001')$$, 'and any summary');
SELECT lives_ok($$UPDATE feedback.reports SET assigned_to = '00000000-0000-0000-0000-000000000003'$$, 'and can assign');
SELECT pg_temp.service();

-- an empty log is stored as none
INSERT INTO r SELECT 'nolog', feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), 'x', '', NULL, NULL);
SELECT is((SELECT log FROM feedback.reports WHERE id = (SELECT id FROM r WHERE name = 'nolog')), NULL, 'an empty log is stored as NULL');
DELETE FROM feedback.reports WHERE id = (SELECT id FROM r WHERE name = 'nolog');

-- the reporter can withdraw the report
SELECT pg_temp.act('00000000-0000-0000-0000-000000000004');
SET LOCAL ROLE authenticated;
DELETE FROM feedback.reports;
SELECT pg_temp.service();
SELECT is((SELECT count(*) FROM feedback.reports), 0::bigint, 'the reporter deleted their report');

-- attachments expire
INSERT INTO r SELECT 'aged', feedback.report_session('00000000-0000-0000-0000-000000000004', (SELECT id FROM s WHERE name = 'open'), 'kept', 'log', '{}', '{}');
UPDATE feedback.reports SET created_at = now() - interval '91 days' WHERE id = (SELECT id FROM r WHERE name = 'aged');
SELECT is(feedback.clear_old_attachments(), 1, 'clear_old_attachments clears the old report');
SELECT is((SELECT (description, log, snapshot, diagnostics) FROM feedback.reports WHERE id = (SELECT id FROM r WHERE name = 'aged')), (('kept'::text, NULL::text, NULL::jsonb, NULL::jsonb)), 'keeping the description');
SELECT is(feedback.clear_old_attachments(), 0, 'and has nothing to do the second time');

SELECT * FROM finish();
ROLLBACK;
