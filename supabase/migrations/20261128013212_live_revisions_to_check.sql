SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION scripts.live_revisions_to_check (
  p_injector text,
  p_limit    integer
)
  RETURNS TABLE (
    id       uuid,
    revision integer
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT v.id, v.revision
  FROM scripts.protected p
  JOIN scripts.versions v ON v.id = p.id AND v.revision = p.revision
  WHERE v.status = 'live'::scripts.version_status
    AND v.checked_injector IS DISTINCT FROM p_injector
    AND COALESCE((v.manifest ->> 'auto_forward')::boolean, true)
  ORDER BY v.checked_at ASC NULLS FIRST
  LIMIT p_limit;
$function$;

REVOKE ALL ON FUNCTION "scripts"."live_revisions_to_check"(text, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "scripts"."live_revisions_to_check"(text, integer) TO "postgres", "service_role";
