-- Every revision is stored encrypted. The files of a revision are AES-256-GCM encrypted by whoever uploads them
-- (the webapp's browser upload and its deploy-token endpoint) under a random key, which goes to scripts.version_keys
-- through set_version_key. The API gives the key to the loader when a session starts, and the loader decrypts in
-- memory. publish_version refuses a revision with no key; revisions published before this stay plain and have no key.

-- The AES-256 key that encrypts the files of one revision (see set_version_key). Only service_role reads it:
-- the API hands it to the loader when a session starts, so the files in the scripts bucket are useless without one.
CREATE TABLE IF NOT EXISTS "scripts"."version_keys" (
    "id" "uuid" NOT NULL,
    "revision" integer NOT NULL,
    "key" "bytea" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "version_keys_key_check" CHECK (octet_length("key") = 32)
);

ALTER TABLE ONLY "scripts"."version_keys"
    ADD CONSTRAINT "version_keys_pkey" PRIMARY KEY ("id", "revision");

ALTER TABLE ONLY "scripts"."version_keys"
    ADD CONSTRAINT "version_keys_version_fkey" FOREIGN KEY ("id", "revision") REFERENCES "scripts"."versions"("id", "revision") ON UPDATE CASCADE ON DELETE CASCADE;

-- Stores the key a pending revision's files were encrypted with, given as 64 hex digits. The encrypted file is
-- nonce (12 bytes) || AES-256-GCM ciphertext and tag, authenticated with "volcren:<script id>/<9-digit revision>/<file>",
-- so it is 28 bytes larger than the plain file and only opens under its own name. The key is set once, before the
-- revision goes live. Same callers as publish_version.
CREATE OR REPLACE FUNCTION "scripts"."set_version_key"("script_id" "uuid", "revision" integer, "key" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND (auth.uid() IS NULL OR profiles.is_banned(auth.uid()) OR NOT (
    scripts.is_author(auth.uid(), script_id) OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
  ) OR NOT profiles.has_accepted_terms(auth.uid())) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF key !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'the key must be 64 lowercase hex digits' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM scripts.versions v
    WHERE v.id = script_id AND v.revision = set_version_key.revision AND v.status = 'pending'::scripts.version_status
  ) THEN
    RAISE EXCEPTION 'no pending revision % of script %', revision, script_id;
  END IF;

  INSERT INTO scripts.version_keys (id, revision, key) VALUES (script_id, revision, decode(key, 'hex'));
END;
$$;

CREATE OR REPLACE FUNCTION "scripts"."publish_version"("script_id" "uuid", "revision" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
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

  -- Every revision is stored encrypted (set_version_key)
  IF NOT EXISTS (SELECT 1 FROM scripts.version_keys k WHERE k.id = script_id AND k.revision = publish_version.revision) THEN
    RAISE EXCEPTION 'revision % of script % has no encryption key', revision, script_id;
  END IF;

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
$$;


-- Encryption keys: no client can read or write them directly
ALTER TABLE "scripts"."version_keys" ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE "scripts"."version_keys" FROM "anon", "authenticated";
GRANT ALL ON TABLE "scripts"."version_keys" TO "service_role";
REVOKE ALL ON FUNCTION "scripts"."set_version_key"("script_id" "uuid", "revision" integer, "key" "text") FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "scripts"."set_version_key"("script_id" "uuid", "revision" integer, "key" "text") TO "authenticated", "service_role";
