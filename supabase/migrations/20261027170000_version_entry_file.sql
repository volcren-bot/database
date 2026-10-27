-- Each revision names the file the loader runs (scripts.versions.entry), so scripts no longer have to
-- be called main.luau. Existing revisions keep running: main.luau if they have one, else their first file.
-- A new revision of one file uses it as the entry; with several files the uploader names it.

ALTER TABLE "scripts"."versions" ADD COLUMN "entry" text;

UPDATE "scripts"."versions"
SET "entry" = CASE WHEN 'main.luau' = ANY("files") THEN 'main.luau' ELSE "files"[1] END;

ALTER TABLE "scripts"."versions" ALTER COLUMN "entry" SET NOT NULL;
ALTER TABLE "scripts"."versions" ADD CONSTRAINT "versions_entry_check" CHECK ("entry" = ANY("files"));

COMMENT ON COLUMN "scripts"."versions"."entry" IS 'The file the loader runs. One of files. Left out on insert, it is the only file of a single-file revision (tr_versions_pre_insert); a revision with several files has to name it.';

GRANT INSERT ("entry") ON TABLE "scripts"."versions" TO "authenticated";

CREATE OR REPLACE FUNCTION "scripts"."tr_versions_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_author uuid;
BEGIN
  UPDATE scripts.protected
  SET last_revision = last_revision + 1
  WHERE id = NEW.id
  RETURNING last_revision, author INTO NEW.revision, v_author;

  NEW.status := 'pending';
  NEW.published_at := NULL;

  -- A single file is the entry. With several, the uploader has to say which one.
  IF NEW.entry IS NULL AND cardinality(NEW.files) = 1 THEN
    NEW.entry := NEW.files[1];
  ELSIF NEW.entry IS NULL THEN
    RAISE EXCEPTION 'a revision with several files needs an entry file' USING ERRCODE = 'invalid_parameter_value';
  END IF;

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
$$;

DROP FUNCTION "payments"."start_session"("uuid", "uuid");

CREATE OR REPLACE FUNCTION "payments"."start_session"("p_user" "uuid", "p_script" "uuid") RETURNS TABLE ("session_id" "uuid", "revision" integer, "files" "text"[], "entry" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_author uuid;
  v_revision integer;
  v_listed_price bigint;
  v_price bigint;
  v_files text[];
  v_entry text;
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

  SELECT v.files, v.entry INTO v_files, v_entry FROM scripts.versions v
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

  RETURN QUERY SELECT v_id, v_revision, v_files, v_entry;
END;
$$;

REVOKE ALL ON FUNCTION "payments"."start_session"("uuid", "uuid") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "payments"."start_session"("uuid", "uuid") TO "service_role";
