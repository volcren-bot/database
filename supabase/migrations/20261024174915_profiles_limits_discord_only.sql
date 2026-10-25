SET local check_function_bodies = off;

REVOKE ALL ("avatar") ON TABLE "profiles"."profiles" FROM "authenticated";

CREATE OR REPLACE FUNCTION profiles.clean_avatar (
  url text
)
  RETURNS text
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT CASE
    WHEN url ~ '^https://' AND char_length(url) <= 512 THEN url
    ELSE ''
  END;
$function$;

CREATE OR REPLACE FUNCTION profiles.clean_username (
  name text,
  id   uuid
)
  RETURNS text
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT CASE
    WHEN char_length(c) >= 2 THEN c
    ELSE 'user-' || left(id::text, 8)
  END
  FROM (
    SELECT btrim(left(btrim(regexp_replace(COALESCE(name, ''), '[[:cntrl:]]', '', 'g')), 32)) AS c
  ) t;
$function$;

CREATE OR REPLACE FUNCTION profiles.get_provider_id (
  user_id  uuid,
  provider text
)
  RETURNS text
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT i.provider_id
  FROM auth.identities i
  WHERE i.user_id = get_provider_id.user_id AND i.provider = get_provider_id.provider
    AND (
      auth.role() = 'service_role'
      OR get_provider_id.user_id = auth.uid()
      OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles)
    )
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION profiles.handle_new_user()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  meta jsonb := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
BEGIN
  INSERT INTO profiles.profiles (id, username, avatar)
  VALUES (
    NEW.id,
    profiles.clean_username(
      COALESCE(
        NULLIF(btrim(regexp_replace(COALESCE(meta -> 'custom_claims' ->> 'global_name', ''), '[[:cntrl:]]', '', 'g')), ''),
        NULLIF(btrim(regexp_replace(COALESCE(meta ->> 'full_name', ''), '[[:cntrl:]]', '', 'g')), ''),
        NULLIF(btrim(regexp_replace(split_part(COALESCE(meta ->> 'name', ''), '#', 1), '[[:cntrl:]]', '', 'g')), ''),
        NULLIF(btrim(regexp_replace(COALESCE(meta ->> 'user_name', ''), '[[:cntrl:]]', '', 'g')), '')
      ),
      NEW.id
    ),
    profiles.clean_avatar(COALESCE(
      NULLIF(meta ->> 'avatar_url', ''),
      NULLIF(meta ->> 'picture', ''),
      ''
    ))
  );
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION profiles.refresh_avatar()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  new_avatar text := profiles.clean_avatar(COALESCE(
    NULLIF(NEW.raw_user_meta_data ->> 'avatar_url', ''),
    NULLIF(NEW.raw_user_meta_data ->> 'picture', '')
  ));
BEGIN
  IF NULLIF(COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', NEW.raw_user_meta_data ->> 'picture'), '') IS NOT NULL THEN
    UPDATE profiles.profiles SET avatar = new_avatar
    WHERE id = NEW.id AND avatar IS DISTINCT FROM new_avatar;
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION profiles.require_discord()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
BEGIN
  IF COALESCE(NEW.raw_app_meta_data ->> 'provider', '') <> 'discord' THEN
    RAISE EXCEPTION 'only Discord sign-in is allowed' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION profiles.scrub_identity_email()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
BEGIN
  NEW.identity_data := NEW.identity_data - 'email';
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION profiles.scrub_user_email()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
BEGIN
  NEW.email := NEW.id::text || '@volcren.com';
  NEW.raw_user_meta_data := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb) - 'email';
  RETURN NEW;
END;
$function$;

ALTER TABLE "profiles"."profiles"
  ADD CONSTRAINT "profiles_avatar_check" CHECK (((avatar = ''::text) OR ((avatar ~ '^https://'::text) AND (char_length(avatar) <= 512))));

ALTER TABLE "profiles"."profiles"
  ADD CONSTRAINT "profiles_username_check"
    CHECK (((username = btrim(username)) AND ((char_length(username) >= 2) AND (char_length(username) <= 32)) AND (username !~ '[[:cntrl:]]'::text)));

CREATE TRIGGER profiles_require_discord
  BEFORE INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION profiles.require_discord();

REVOKE ALL ON FUNCTION "profiles"."clean_avatar"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "profiles"."clean_avatar"(text) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "profiles"."clean_username"(text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "profiles"."clean_username"(text, uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "profiles"."require_discord"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "profiles"."require_discord"() TO "postgres";
