-- Schema: public (rewritten for Volcren)
--
-- Only the HMAC helper and the signed webhook function live here.
-- Apply order: public -> profiles -> scripts -> payments -> stats -> info (scripts.can_access reads payments.accounts at call time)


CREATE SCHEMA IF NOT EXISTS "public";

ALTER SCHEMA "public" OWNER TO "pg_database_owner";

COMMENT ON SCHEMA "public" IS 'standard public schema';

CREATE OR REPLACE FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT encode(extensions.hmac(message::bytea, secret_key::bytea, 'sha256'), 'base64');
$$;


-- Row trigger that POSTs the change to the webapp, signed with an HMAC in
-- X-Supabase-Signature. Both values come from the vault:
--   WEBHOOK_SECRET    HMAC key
--   WEBHOOK_BASE_URL  e.g. https://volcren.com/api/supabase
-- The request goes to <WEBHOOK_BASE_URL>/<schema>/<table>. If either secret is
-- missing the trigger does nothing, so local setups work without the webapp.
CREATE OR REPLACE FUNCTION "public"."webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    secret text;
    base_url text;
    payload jsonb;
    request_id bigint;
BEGIN
    SELECT decrypted_secret INTO secret FROM vault.decrypted_secrets WHERE name = 'WEBHOOK_SECRET' LIMIT 1;
    SELECT decrypted_secret INTO base_url FROM vault.decrypted_secrets WHERE name = 'WEBHOOK_BASE_URL' LIMIT 1;

    IF secret IS NULL OR base_url IS NULL THEN
        RETURN NULL;
    END IF;

    payload := jsonb_build_object(
        'old_record', old,
        'record', new,
        'type', tg_op,
        'table', tg_table_name,
        'schema', tg_table_schema
    );

    SELECT net.http_post(
        format('%s/%s/%s', rtrim(base_url, '/'), tg_table_schema, tg_table_name),
        payload,
        '{}',
        jsonb_build_object(
            'Content-Type', 'application/json',
            'X-Supabase-Signature', public.generate_hmac(secret, payload::text)
        ),
        4000
    ) INTO request_id;

    INSERT INTO supabase_functions.hooks (hook_table_id, hook_name, request_id)
    VALUES (tg_relid, tg_name, request_id);

    RETURN NULL;
END;
$$;


-- Privileges: the webhook runs only from triggers, the HMAC helper only from service_role

REVOKE ALL ON FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "public"."webhook"() FROM PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") TO "service_role";

GRANT USAGE ON SCHEMA "public" TO "postgres", "anon", "authenticated", "service_role";
