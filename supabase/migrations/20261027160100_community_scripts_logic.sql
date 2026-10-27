SET local check_function_bodies = off;

ALTER TABLE "info"."acceptances"
  ADD COLUMN "kind" info.kind NOT NULL;

CREATE OR REPLACE FUNCTION info.accept_terms (
  p_kind    info.kind,
  p_version integer
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_kind NOT IN ('scripter_tos'::info.kind, 'community_tos'::info.kind) THEN
    RAISE EXCEPTION 'only the scripter and community terms are accepted' USING ERRCODE = 'check_violation';
  END IF;

  IF p_version IS DISTINCT FROM (SELECT max(d.version) FROM info.documents d WHERE d.kind = p_kind) THEN
    RAISE EXCEPTION 'only the current version can be accepted' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO info.acceptances (user_id, kind, version) VALUES (auth.uid(), p_kind, p_version)
  ON CONFLICT DO NOTHING;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.heartbeat_session (
  p_session uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_session payments.sessions;
  v_minutes integer;
  v_balance bigint;
BEGIN
  SELECT * INTO v_session FROM payments.sessions WHERE id = p_session FOR UPDATE;

  IF NOT FOUND OR v_session.ended_at IS NOT NULL THEN
    RETURN false;
  END IF;

  -- A banned author's scripts stop for everyone, running sessions included
  IF scripts.author_is_banned(v_session.script_id) THEN
    PERFORM payments.end_session(p_session, 'stopped');
    RETURN false;
  END IF;

  UPDATE payments.sessions SET last_seen = now() WHERE id = p_session;

  v_minutes := floor(extract(epoch FROM (now() - v_session.charged_until)) / 60)::integer;

  IF v_minutes >= 1 THEN
    PERFORM payments.charge_session(p_session, v_minutes);

    UPDATE payments.sessions SET charged_until = charged_until + make_interval(mins => v_minutes) WHERE id = p_session;
  END IF;

  IF v_session.price > 0 THEN
    SELECT credits INTO v_balance FROM payments.accounts WHERE user_id = v_session.user_id;

    IF COALESCE(v_balance, 0) < payments.required_balance(v_session.price) THEN
      PERFORM payments.end_session(p_session, 'insufficient_credits');
      RETURN false;
    END IF;
  END IF;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.start_session (
  p_user   uuid,
  p_script uuid
)
  RETURNS TABLE (
    session_id uuid,
    revision   integer,
    files      text[]
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_author uuid;
  v_revision integer;
  v_listed_price bigint;
  v_price bigint;
  v_files text[];
  v_id uuid;
BEGIN
  IF profiles.is_banned(p_user) THEN
    RAISE EXCEPTION 'account banned' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT scripts.can_access(p_user, p_script) OR scripts.author_is_banned(p_script) THEN
    RAISE EXCEPTION 'script not accessible' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT p.author, p.revision, m.price INTO v_author, v_revision, v_listed_price
  FROM scripts.protected p
  JOIN scripts.metadata m ON m.id = p.id
  WHERE p.id = p_script;

  SELECT v.files INTO v_files FROM scripts.versions v
  WHERE v.id = p_script AND v.revision = v_revision AND v.status = 'live'::scripts.version_status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'script % has no live revision', p_script;
  END IF;

  v_price := CASE
    WHEN v_author = p_user OR profiles.min_role(p_user, 'tester'::profiles.roles) OR scripts.has_grant(p_user, p_script) THEN 0
    ELSE v_listed_price
  END;

  IF v_price > 0 AND COALESCE((SELECT a.credits FROM payments.accounts a WHERE a.user_id = p_user), 0)
                     < payments.required_balance(v_price) THEN
    RAISE EXCEPTION 'insufficient credits' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO payments.sessions AS s (user_id, script_id, author_id, revision, price)
  VALUES (p_user, p_script, v_author, v_revision, v_price)
  RETURNING s.id INTO v_id;

  RETURN QUERY SELECT v_id, v_revision, v_files;
END;
$function$;

CREATE OR REPLACE FUNCTION profiles.has_accepted_terms (
  user_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT (auth.role() = 'service_role' OR user_id = auth.uid())
    AND COALESCE((
      SELECT NOT EXISTS (
        SELECT 1
        FROM unnest(ARRAY['scripter_tos'::info.kind, 'community_tos'::info.kind]) k
        CROSS JOIN LATERAL (SELECT max(d.version) AS version FROM info.documents d WHERE d.kind = k) l
        WHERE CASE
          WHEN l.version IS NULL THEN p.role < 'scripter'::profiles.roles
          ELSE NOT EXISTS (
            SELECT 1 FROM info.acceptances a
            WHERE a.user_id = has_accepted_terms.user_id AND a.kind = k AND a.version = l.version
          )
        END
      )
      FROM profiles.profiles p
      WHERE p.id = user_id
    ), false);
$function$;

CREATE OR REPLACE FUNCTION profiles.tr_profiles_role_change()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  IF OLD.role < 'scripter'::profiles.roles AND NEW.role >= 'scripter'::profiles.roles THEN
    UPDATE scripts.scripts s SET published = false
    FROM scripts.protected p
    WHERE p.id = s.id AND p.author = NEW.id AND s.published;
  ELSIF OLD.role >= 'scripter'::profiles.roles AND NEW.role < 'scripter'::profiles.roles THEN
    UPDATE scripts.metadata m SET type = 'free'::scripts.type, price = 0
    FROM scripts.protected p
    WHERE p.id = m.id AND p.author = NEW.id AND (m.type <> 'free'::scripts.type OR m.price <> 0);

    IF NEW.role = 'user'::profiles.roles AND EXISTS (SELECT 1 FROM scripts.protected p WHERE p.author = NEW.id) THEN
      NEW.role := 'contributor'::profiles.roles;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.author_banned (
  s scripts.scripts
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT profiles.min_role(auth.uid(), 'moderator'::profiles.roles) AND scripts.author_is_banned(s.id);
$function$;

CREATE OR REPLACE FUNCTION scripts.author_is_banned (
  script_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT COALESCE((
    SELECT a.banned_at IS NOT NULL
    FROM scripts.protected p
    JOIN profiles.profiles a ON a.id = p.author
    WHERE p.id = script_id
  ), false);
$function$;

CREATE OR REPLACE FUNCTION scripts.author_is_community (
  script_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT COALESCE((
    SELECT a.role < 'scripter'::profiles.roles
    FROM scripts.protected p
    JOIN profiles.profiles a ON a.id = p.author
    WHERE p.id = script_id
  ), false);
$function$;

CREATE OR REPLACE FUNCTION scripts.can_access (
  accesser_id uuid,
  script_id   uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
      WITH viewer AS (
              SELECT role FROM profiles.profiles WHERE id = accesser_id
      ),
      script AS (
              SELECT p.author, p.revision, m.type, m.stage, m.price, s.published,
                     a.role AS author_role, a.banned_at IS NOT NULL AS author_banned,
                     EXISTS (SELECT 1 FROM scripts.grants g WHERE g.script_id = s.id AND g.user_id = accesser_id) AS granted
              FROM scripts.scripts s
              JOIN scripts.metadata m ON m.id = s.id
              JOIN scripts.protected p ON p.id = s.id
              JOIN profiles.profiles a ON a.id = p.author
              WHERE s.id = script_id
      )
      SELECT
              (accesser_id IS NOT DISTINCT FROM auth.uid() OR COALESCE(auth.role(), 'service_role') = 'service_role')
              AND COALESCE((
                      SELECT
                              sc.revision > 0
                              AND (NOT sc.author_banned OR COALESCE(v.role >= 'moderator'::profiles.roles, false))
                              AND (
                              sc.author = accesser_id
                              OR v.role >= 'moderator'::profiles.roles
                              OR sc.granted
                              OR (
                                      CASE
                                              WHEN sc.author_role < 'scripter'::profiles.roles THEN v.role >= 'tester'::profiles.roles
                                              ELSE (
                                                      CASE sc.stage
                                                              WHEN 'alpha'::scripts.stage THEN v.role >= 'tester'::profiles.roles
                                                              WHEN 'beta'::scripts.stage THEN sc.published
                                                              WHEN 'stable'::scripts.stage THEN sc.published
                                                              ELSE false
                                                      END
                                                      AND (
                                                              sc.type <> 'premium'::scripts.type
                                                              OR v.role >= 'tester'::profiles.roles
                                                              OR COALESCE((SELECT a.credits FROM payments.accounts a WHERE a.user_id = accesser_id), 0) >= payments.required_balance(sc.price)
                                                      )
                                              )
                                      END
                              )
                              )
                      FROM script sc
                      LEFT JOIN viewer v ON true
              ), false);
$function$;

CREATE OR REPLACE FUNCTION scripts.can_create_script()
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT auth.uid() IS NOT NULL
    AND profiles.has_accepted_terms(auth.uid())
    AND (profiles.min_role(auth.uid(), 'scripter'::profiles.roles) OR NOT profiles.is_banned(auth.uid()));
$function$;

CREATE OR REPLACE FUNCTION scripts.can_upload (
  object_name text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM scripts.versions v
    WHERE v.id = scripts.safe_uuid(split_part(object_name, '/', 1))
      AND v.status = 'pending'::scripts.version_status
      AND starts_with(object_name, v.id::text || '/' || lpad(v.revision::text, 9, '0') || '/')
      AND substr(object_name, length(v.id::text || '/' || lpad(v.revision::text, 9, '0') || '/') + 1) = ANY (v.files)
      AND (
        scripts.is_author(auth.uid(), v.id)
        OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
      )
      AND profiles.has_accepted_terms(auth.uid())
  );
$function$;

CREATE OR REPLACE FUNCTION scripts.can_view (
  viewer_id uuid,
  script_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
      SELECT COALESCE((
        SELECT
          CASE
            WHEN COALESCE(v.role >= 'moderator'::profiles.roles, false) THEN true
            WHEN a.banned_at IS NOT NULL THEN false
            WHEN p.author = viewer_id THEN true
            WHEN EXISTS (SELECT 1 FROM scripts.grants g WHERE g.script_id = s.id AND g.user_id = viewer_id) THEN true
            WHEN a.role < 'scripter'::profiles.roles THEN COALESCE(v.role >= 'tester'::profiles.roles, false)
            ELSE
              p.revision > 0
              AND CASE m.stage
                    WHEN 'archived'::scripts.stage THEN false
                    WHEN 'prototype'::scripts.stage THEN false
                    WHEN 'alpha'::scripts.stage THEN COALESCE(v.role >= 'tester'::profiles.roles, false)
                    ELSE s.published
                  END
          END
        FROM scripts.scripts s
        LEFT JOIN scripts.protected p ON p.id = s.id
        LEFT JOIN scripts.metadata m ON m.id = s.id
        LEFT JOIN profiles.profiles a ON a.id = p.author
        LEFT JOIN profiles.profiles v ON v.id = viewer_id
        WHERE s.id = script_id
      ), false);
$function$;

CREATE OR REPLACE FUNCTION scripts.create_share_code (
  p_script     uuid,
  p_expires_at timestamp with time zone
)
  RETURNS TABLE (
    id         uuid,
    code       text,
    expires_at timestamp with time zone
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_cfg scripts.config;
  v_code text;
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR profiles.is_banned(auth.uid()) OR NOT (
    scripts.is_author(auth.uid(), p_script) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  ) OR NOT profiles.has_accepted_terms(auth.uid()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM scripts.scripts s WHERE s.id = p_script) THEN
    RAISE EXCEPTION 'script % not found', p_script USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_cfg FROM scripts.config;

  IF p_expires_at IS NULL OR p_expires_at <= now() OR p_expires_at > now() + make_interval(days => v_cfg.max_share_code_days) THEN
    RAISE EXCEPTION 'a share code expires within % days from now', v_cfg.max_share_code_days USING ERRCODE = 'check_violation';
  END IF;

  -- Concurrent creations for one script queue here, so each counts the others' codes
  PERFORM pg_advisory_xact_lock(hashtext('scripts.share_codes.' || p_script::text));

  IF (SELECT count(*) FROM scripts.share_codes c WHERE c.script_id = p_script AND c.redeemed_at IS NULL AND c.expires_at > now()) >= v_cfg.max_open_share_codes THEN
    RAISE EXCEPTION 'a script can have at most % open share codes', v_cfg.max_open_share_codes USING ERRCODE = 'check_violation';
  END IF;

  v_code := encode(extensions.gen_random_bytes(32), 'hex');

  INSERT INTO scripts.share_codes AS c (script_id, code_hash, expires_at)
  VALUES (p_script, encode(extensions.digest(v_code, 'sha256'), 'hex'), p_expires_at)
  RETURNING c.id INTO v_id;

  RETURN QUERY SELECT v_id, v_code, p_expires_at;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.delete_expired_share_codes()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_count integer;
BEGIN
  DELETE FROM scripts.share_codes c WHERE c.redeemed_at IS NULL AND c.expires_at < now();
  GET DIAGNOSTICS v_count = ROW_COUNT;

  DELETE FROM scripts.redeem_attempts a
  WHERE a.attempted_at < now() - make_interval(mins => (SELECT c.redeem_window_minutes FROM scripts.config c));

  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.get_community_usage()
  RETURNS TABLE (
    script_count integer,
    used_bytes   bigint,
    max_scripts  integer,
    max_bytes    bigint
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT
    (SELECT count(*)::integer FROM scripts.protected p WHERE p.author = auth.uid()),
    scripts.storage_used(auth.uid()),
    c.max_community_scripts,
    c.max_community_bytes
  FROM scripts.config c
  WHERE auth.uid() IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION scripts.has_grant (
  user_id   uuid,
  script_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT EXISTS (SELECT 1 FROM scripts.grants g WHERE g.user_id = has_grant.user_id AND g.script_id = has_grant.script_id);
$function$;

CREATE OR REPLACE FUNCTION scripts.is_community (
  s scripts.scripts
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT scripts.author_is_community(s.id);
$function$;

CREATE OR REPLACE FUNCTION scripts.is_granted (
  s scripts.scripts
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT COALESCE(scripts.has_grant(auth.uid(), s.id), false);
$function$;

CREATE OR REPLACE FUNCTION scripts.is_reviewable (
  script_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT scripts.author_is_community(script_id) AND NOT scripts.author_is_banned(script_id);
$function$;

CREATE OR REPLACE FUNCTION scripts.list_grantees (
  p_script uuid
)
  RETURNS TABLE (
    user_id    uuid,
    username   text,
    granted_at timestamp with time zone
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT g.user_id, u.username, g.granted_at
  FROM scripts.grants g
  JOIN profiles.profiles u ON u.id = g.user_id
  WHERE g.script_id = p_script
    AND (scripts.is_author(auth.uid(), p_script) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles))
  ORDER BY g.granted_at;
$function$;

CREATE OR REPLACE FUNCTION scripts.publish_version (
  script_id uuid,
  revision  integer
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_version scripts.versions;
  v_file text;
  v_author uuid;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND (auth.uid() IS NULL OR profiles.is_banned(auth.uid()) OR NOT (
    scripts.is_author(auth.uid(), script_id) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  ) OR NOT profiles.has_accepted_terms(auth.uid())) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_version FROM scripts.versions v
  WHERE v.id = script_id AND v.revision = publish_version.revision
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'revision % of script % not found', revision, script_id;
  END IF;

  IF v_version.status <> 'pending' THEN
    RAISE EXCEPTION 'revision % is %, only a pending revision can be published', revision, v_version.status;
  END IF;

  FOREACH v_file IN ARRAY v_version.files LOOP
    IF NOT EXISTS (
      SELECT 1 FROM storage.objects o
      WHERE o.bucket_id = 'scripts'
        AND o.name = script_id::text || '/' || lpad(revision::text, 9, '0') || '/' || v_file
    ) THEN
      RAISE EXCEPTION 'file % of revision % is not uploaded', v_file, revision;
    END IF;
  END LOOP;

  -- The real sizes of a community author's files have to fit their storage, whatever was declared
  IF scripts.author_is_community(script_id) THEN
    SELECT p.author INTO v_author FROM scripts.protected p WHERE p.id = script_id;

    PERFORM pg_advisory_xact_lock(hashtext('scripts.storage.' || v_author::text));

    IF scripts.storage_used(v_author, false) > (SELECT c.max_community_bytes FROM scripts.config c) THEN
      RAISE EXCEPTION 'community storage limit reached' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  UPDATE scripts.versions v SET status = 'live', published_at = now()
  WHERE v.id = script_id AND v.revision = publish_version.revision;

  UPDATE scripts.protected p SET revision = publish_version.revision, updated_at = now()
  WHERE p.id = script_id;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.redeem_share_code (
  p_code text
)
  RETURNS TABLE (
    status    text,
    script_id uuid,
    url       text
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_cfg scripts.config;
  v_code scripts.share_codes;
  v_author uuid;
  v_clean text := lower(btrim(COALESCE(p_code, '')));
  v_status text;
  v_url text;
  v_rows integer;
BEGIN
  IF v_user IS NULL OR profiles.is_banned(v_user) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_cfg FROM scripts.config;

  -- One redemption of an account at a time: the attempt count below can't be raced past
  PERFORM pg_advisory_xact_lock(hashtext('scripts.redeem.' || v_user::text));

  IF (SELECT count(*) FROM scripts.redeem_attempts a
      WHERE a.user_id = v_user AND a.attempted_at > now() - make_interval(mins => v_cfg.redeem_window_minutes)) >= v_cfg.redeem_max_failures THEN
    RETURN QUERY SELECT 'rate_limited'::text, NULL::uuid, NULL::text;
    RETURN;
  END IF;

  IF v_clean !~ '^[0-9a-f]{64}$' THEN
    v_status := 'invalid';
  ELSE
    SELECT * INTO v_code FROM scripts.share_codes c
    WHERE c.code_hash = encode(extensions.digest(v_clean, 'sha256'), 'hex')
    FOR UPDATE;

    IF NOT FOUND THEN
      v_status := 'invalid';
    ELSE
      SELECT p.author INTO v_author FROM scripts.protected p WHERE p.id = v_code.script_id;

      IF profiles.is_banned(v_author) THEN
        v_status := 'invalid';
      ELSIF v_code.redeemed_at IS NOT NULL THEN
        v_status := 'used';
      ELSIF v_code.expires_at <= now() THEN
        v_status := 'expired';
      ELSIF v_author = v_user OR v_code.created_by = v_user THEN
        v_status := 'own';
      ELSIF scripts.can_view(v_user, v_code.script_id) THEN
        v_status := 'already_access';
      ELSE
        INSERT INTO scripts.grants (script_id, user_id, code_id) VALUES (v_code.script_id, v_user, v_code.id)
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_rows = ROW_COUNT;

        IF v_rows = 0 THEN
          v_status := 'already_access';
        ELSE
          UPDATE scripts.share_codes c SET redeemed_by = v_user, redeemed_at = now() WHERE c.id = v_code.id;
          SELECT s.url INTO v_url FROM scripts.scripts s WHERE s.id = v_code.script_id;
          v_status := 'ok';
        END IF;
      END IF;
    END IF;
  END IF;

  IF v_status IN ('invalid', 'used', 'expired') THEN
    INSERT INTO scripts.redeem_attempts (user_id) VALUES (v_user);
  END IF;

  RETURN QUERY SELECT v_status, CASE WHEN v_status = 'ok' THEN v_code.script_id END, v_url;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.storage_used (
  author_id       uuid,
  reserve_pending boolean DEFAULT true
)
  RETURNS bigint
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT COALESCE(sum(
    CASE WHEN reserve_pending AND v.status = 'pending'::scripts.version_status THEN GREATEST(d.declared, r.stored) ELSE r.stored END
  ), 0)::bigint
  FROM scripts.protected p
  JOIN scripts.versions v ON v.id = p.id
  CROSS JOIN LATERAL (
    SELECT COALESCE(sum((o.metadata ->> 'size')::bigint), 0) AS stored
    FROM storage.objects o
    WHERE o.bucket_id = 'scripts'
      AND o.name LIKE v.id::text || '/' || lpad(v.revision::text, 9, '0') || '/%'
  ) r
  CROSS JOIN LATERAL (SELECT COALESCE(sum(z), 0) AS declared FROM unnest(v.sizes) z) d
  WHERE p.author = author_id;
$function$;

CREATE OR REPLACE FUNCTION scripts.tr_metadata_pre_update()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
BEGIN
  IF NEW.stage < OLD.stage THEN
    RAISE EXCEPTION
      'Invalid stage transition: % → % is not allowed',
      OLD.stage, NEW.stage
      USING ERRCODE = 'check_violation';
  END IF;

  IF (NEW.type <> 'free'::scripts.type OR NEW.price <> 0) AND scripts.author_is_community(NEW.id) THEN
    RAISE EXCEPTION 'community scripts cannot be premium' USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.tr_protected_post_delete()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM scripts.protected p WHERE p.author = OLD.author) THEN
    UPDATE profiles.profiles p SET role = 'user'::profiles.roles
    WHERE p.id = OLD.author AND p.role = 'contributor'::profiles.roles;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.tr_scripts_post_insert()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_role profiles.roles;
BEGIN
  INSERT INTO scripts.protected (id, author) VALUES (NEW.id, auth.uid());
  INSERT INTO scripts.metadata (id) VALUES (NEW.id);
  INSERT INTO stats.limits (id) VALUES (NEW.id);
  INSERT INTO stats.limits_custom (id) VALUES (NEW.id);
  INSERT INTO stats.values (id) VALUES (NEW.id);
  INSERT INTO stats.values_custom (id) VALUES (NEW.id);
  INSERT INTO stats.website (id) VALUES (NEW.id);

  SELECT p.role INTO v_role FROM profiles.profiles p WHERE p.id = auth.uid();

  IF v_role < 'scripter'::profiles.roles THEN
    -- Concurrent inserts of one author queue here, so each counts the others' scripts
    PERFORM pg_advisory_xact_lock(hashtext('scripts.community.' || auth.uid()::text));

    IF (SELECT count(*) FROM scripts.protected p WHERE p.author = auth.uid()) > (SELECT c.max_community_scripts FROM scripts.config c) THEN
      RAISE EXCEPTION 'community script limit reached' USING ERRCODE = 'check_violation';
    END IF;

    UPDATE profiles.profiles p SET role = 'contributor'::profiles.roles WHERE p.id = auth.uid() AND p.role = 'user'::profiles.roles;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.tr_versions_pre_insert()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_author uuid;
BEGIN
  UPDATE scripts.protected
  SET last_revision = last_revision + 1
  WHERE id = NEW.id
  RETURNING last_revision, author INTO NEW.revision, v_author;

  NEW.status := 'pending';
  NEW.published_at := NULL;

  -- A community author declares every file's size, and the revision has to fit what is left of
  -- their storage. The declared sizes can lie: publish_version checks the real ones.
  IF scripts.author_is_community(NEW.id) THEN
    IF cardinality(NEW.sizes) <> cardinality(NEW.files) THEN
      RAISE EXCEPTION 'every file needs its size' USING ERRCODE = 'check_violation';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('scripts.storage.' || v_author::text));

    IF scripts.storage_used(v_author) + (SELECT COALESCE(sum(z), 0) FROM unnest(NEW.sizes) z) > (SELECT c.max_community_bytes FROM scripts.config c) THEN
      RAISE EXCEPTION 'community storage limit reached' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION scripts.use_deploy_token (
  p_script     uuid,
  p_token_hash text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
DECLARE
  v_id uuid;
BEGIN
  UPDATE scripts.deploy_tokens t SET last_used_at = now()
  WHERE t.script_id = p_script AND t.token_hash = p_token_hash
    AND (scripts.is_author(t.created_by, t.script_id) OR profiles.min_role(t.created_by, 'moderator'::profiles.roles))
    AND NOT profiles.is_banned(t.created_by)
    AND profiles.has_accepted_terms(t.created_by)
  RETURNING t.id INTO v_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid deploy token' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN v_id;
END;
$function$;

ALTER TABLE "info"."acceptances"
  ADD CONSTRAINT "acceptances_document_fkey" FOREIGN KEY (kind, VERSION) REFERENCES info.documents(kind, VERSION);

ALTER TABLE "info"."acceptances"
  ADD CONSTRAINT "acceptances_pkey" PRIMARY KEY (user_id, kind, VERSION);

ALTER TABLE "info"."acceptances"
  ADD CONSTRAINT "acceptances_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles.profiles(id) ON DELETE CASCADE;

ALTER TABLE "scripts"."grants"
  ADD CONSTRAINT "grants_script_id_fkey" FOREIGN KEY (script_id) REFERENCES scripts.scripts(id) ON DELETE CASCADE;

ALTER TABLE "scripts"."grants"
  ADD CONSTRAINT "grants_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles.profiles(id) ON DELETE CASCADE;

ALTER TABLE "scripts"."redeem_attempts"
  ADD CONSTRAINT "redeem_attempts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles.profiles(id) ON DELETE CASCADE;

ALTER TABLE "scripts"."grants"
  ADD CONSTRAINT "grants_code_id_fkey" FOREIGN KEY (code_id) REFERENCES scripts.share_codes(id) ON DELETE CASCADE;

ALTER TABLE "scripts"."share_codes"
  ADD CONSTRAINT "share_codes_redeemed_by_fkey" FOREIGN KEY (redeemed_by) REFERENCES profiles.profiles(id) ON DELETE CASCADE;

ALTER TABLE "scripts"."share_codes"
  ADD CONSTRAINT "share_codes_script_id_fkey" FOREIGN KEY (script_id) REFERENCES scripts.scripts(id) ON DELETE CASCADE;

ALTER TABLE "scripts"."versions"
  ADD CONSTRAINT "versions_sizes_check" CHECK ((((cardinality(sizes) = 0) OR (cardinality(sizes) = cardinality(files))) AND (0 <= ALL (sizes))));

CREATE INDEX grants_user_id_idx ON scripts.grants USING btree (user_id);

CREATE INDEX redeem_attempts_user_id_idx ON scripts.redeem_attempts USING btree (user_id, attempted_at);

CREATE INDEX share_codes_script_id_idx ON scripts.share_codes USING btree (script_id);

CREATE TRIGGER tr_profiles_role_change
  BEFORE UPDATE OF ROLE ON profiles.profiles
  FOR EACH ROW
  WHEN ((old.role IS DISTINCT FROM new.role))
  EXECUTE FUNCTION profiles.tr_profiles_role_change();

CREATE TRIGGER tr_protected_post_delete
  AFTER DELETE ON scripts.protected
  FOR EACH ROW
  EXECUTE FUNCTION scripts.tr_protected_post_delete();

CREATE POLICY "SELECT for OWNER" ON "info"."acceptances"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "SELECT for EVERYONE" ON "scripts"."config"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "DELETE for HOLDER and AUTHOR" ON "scripts"."grants"
  FOR DELETE
  TO "authenticated"
  USING (((user_id = profiles.uid()) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles) OR scripts.is_author(profiles.uid(), script_id)));

CREATE POLICY "SELECT for HOLDER and AUTHOR" ON "scripts"."grants"
  FOR SELECT
  TO "authenticated"
  USING (((user_id = profiles.uid()) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles) OR scripts.is_author(profiles.uid(), script_id)));

CREATE POLICY "DELETE for MODERATOR" ON "scripts"."scripts"
  FOR DELETE
  TO "authenticated"
  USING (profiles.min_role(profiles.uid(), 'moderator'::profiles.roles));

CREATE POLICY "INSERT for ALLOWED" ON "scripts"."scripts"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (scripts.can_create_script());

CREATE POLICY "DELETE for AUTHOR" ON "scripts"."share_codes"
  FOR DELETE
  TO "authenticated"
  USING (((redeemed_at IS NULL) AND (profiles.min_role(profiles.uid(), 'moderator'::profiles.roles) OR scripts.is_author(profiles.uid(), script_id))));

CREATE POLICY "SELECT for AUTHOR" ON "scripts"."share_codes"
  FOR SELECT
  TO "authenticated"
  USING ((profiles.min_role(profiles.uid(), 'moderator'::profiles.roles) OR scripts.is_author(profiles.uid(), script_id)));

CREATE POLICY "INSERT for AUTHOR" ON "scripts"."versions"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((profiles.min_role(profiles.uid(), 'moderator'::profiles.roles) OR scripts.is_author(profiles.uid(), id)) AND profiles.has_accepted_terms(profiles.uid())));

CREATE POLICY "SELECT for AUTHOR" ON "scripts"."versions"
  FOR SELECT
  TO "authenticated"
  USING
    ((scripts.is_author(profiles.uid(), id) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles) OR (profiles.min_role(profiles.uid(), 'tester'::profiles.roles) AND
    scripts.is_reviewable(id))));

CREATE POLICY "scripts SELECT for author" ON "storage"."objects"
  FOR SELECT
  TO "authenticated"
  USING
    (((bucket_id = 'scripts'::text) AND (scripts.is_object_author(profiles.uid(), name) OR profiles.min_role(profiles.uid(), 'moderator'::profiles.roles) OR
    (profiles.min_role(profiles.uid(), 'tester'::profiles.roles) AND scripts.is_reviewable(scripts.safe_uuid(split_part(name, '/'::text, 1)))))));

COMMENT ON COLUMN "scripts"."config"."max_community_bytes" IS 'Bytes of stored script files (every revision, pending, live or old) a community author can have: 30 MiB.';

COMMENT ON COLUMN "scripts"."config"."max_community_scripts" IS 'Scripts a community author (role below scripter) can have. Scripter+ has no limit.';

COMMENT ON COLUMN "scripts"."config"."max_open_share_codes" IS 'Unredeemed, unexpired share codes a script can have at a time.';

COMMENT ON COLUMN "scripts"."config"."max_share_code_days" IS 'The furthest a share code expiry can be set.';

COMMENT ON COLUMN "scripts"."config"."redeem_max_failures" IS 'Failed share code redemptions an account gets per redeem_window_minutes before redeem_share_code stops answering.';

COMMENT ON COLUMN "scripts"."versions"."sizes" IS 'Byte size of each file in files, in the same order. Required for community authors, who are capped on storage; the real sizes are checked again when the revision goes live (publish_version).';

REVOKE ALL ON FUNCTION "info"."accept_terms"(info.kind, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "info"."accept_terms"(info.kind, integer) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "profiles"."has_accepted_terms"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "profiles"."has_accepted_terms"(uuid) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "profiles"."tr_profiles_role_change"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "profiles"."tr_profiles_role_change"() TO "postgres";

GRANT EXECUTE ON FUNCTION "scripts"."author_banned"(scripts.scripts) TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."author_is_banned"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."author_is_banned"(uuid) TO "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "scripts"."author_is_community"(uuid) TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."can_create_script"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."can_create_script"() TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."create_share_code"(uuid, timestamp WITH time zone) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."create_share_code"(uuid, timestamp WITH time zone) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."delete_expired_share_codes"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."delete_expired_share_codes"() TO "postgres";

REVOKE ALL ON FUNCTION "scripts"."get_community_usage"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."get_community_usage"() TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."has_grant"(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."has_grant"(uuid, uuid) TO "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "scripts"."is_community"(scripts.scripts) TO "anon", "authenticated", "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "scripts"."is_granted"(scripts.scripts) TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."is_reviewable"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."is_reviewable"(uuid) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."list_grantees"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."list_grantees"(uuid) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."redeem_share_code"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."redeem_share_code"(text) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."storage_used"(uuid, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."storage_used"(uuid, boolean) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "scripts"."tr_protected_post_delete"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."tr_protected_post_delete"() TO "postgres";

GRANT SELECT ON TABLE "info"."acceptances" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "info"."acceptances" TO "postgres", "service_role";

GRANT SELECT ON TABLE "scripts"."config" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "scripts"."config" TO "postgres", "service_role";

GRANT SELECT ("granted_at") ON TABLE "scripts"."grants" TO "authenticated";

GRANT SELECT ("script_id") ON TABLE "scripts"."grants" TO "authenticated";

GRANT SELECT ("user_id") ON TABLE "scripts"."grants" TO "authenticated";

GRANT DELETE ON TABLE "scripts"."grants" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "scripts"."grants" TO "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "scripts"."redeem_attempts" TO "postgres", "service_role";

-- Only DELETE is new. (The generated REVOKE ALL / GRANT DELETE, SELECT pair would also have dropped
-- the column grants authors use to insert and update their scripts.)
GRANT DELETE ON TABLE "scripts"."scripts" TO "authenticated";

GRANT SELECT ("created_at") ON TABLE "scripts"."share_codes" TO "authenticated";

GRANT SELECT ("expires_at") ON TABLE "scripts"."share_codes" TO "authenticated";

GRANT SELECT ("id") ON TABLE "scripts"."share_codes" TO "authenticated";

GRANT SELECT ("redeemed_at") ON TABLE "scripts"."share_codes" TO "authenticated";

GRANT SELECT ("script_id") ON TABLE "scripts"."share_codes" TO "authenticated";

GRANT DELETE ON TABLE "scripts"."share_codes" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "scripts"."share_codes" TO "postgres", "service_role";

REVOKE ALL ("sizes") ON TABLE "scripts"."versions" FROM "authenticated";

GRANT INSERT ("sizes") ON TABLE "scripts"."versions" TO "authenticated";

ALTER TABLE "scripts"."share_codes"
  ADD CONSTRAINT "share_codes_created_by_fkey" FOREIGN KEY (created_by) REFERENCES profiles.profiles(id) ON DELETE CASCADE;

GRANT SELECT ("created_by") ON TABLE "scripts"."share_codes" TO "authenticated";

-- ==== Hand-written (no schema diff captures these) ====

-- The community limits; the table holds this one row and nothing else
INSERT INTO "scripts"."config" ("id") VALUES (true);

-- Existing scripter+ keep working: they accepted the current scripter_tos on the old, untracked
-- terms. A community_tos published later (or a new scripter_tos) asks everyone again.
INSERT INTO "info"."acceptances" ("user_id", "kind", "version")
SELECT p."id", d."kind", d."version"
FROM "profiles"."profiles" p
CROSS JOIN LATERAL (
    SELECT "kind", "version" FROM "info"."documents"
    WHERE "kind" = 'scripter_tos'::"info"."kind"
    ORDER BY "version" DESC LIMIT 1
) d
WHERE p."role" >= 'scripter'::"profiles"."roles";

-- Drops share codes that expired unredeemed, and old failed redemptions. cron.schedule with a name
-- replaces an existing job of that name.
SELECT cron.schedule('scripts-delete-expired-share-codes', '17 * * * *', $$SELECT scripts.delete_expired_share_codes()$$);
