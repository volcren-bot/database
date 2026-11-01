-- payments.average_price: the database now returns the monthly estimate's average to the logged-in user, over runnable scripts only.

CREATE OR REPLACE FUNCTION "payments"."average_price"() RETURNS numeric
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
  SELECT avg(m.price)
  FROM scripts.scripts s
  JOIN scripts.metadata m ON m.id = s.id
  JOIN scripts.protected p ON p.id = s.id
  WHERE s.published
    AND m.price > 0
    AND p.revision > 0
    AND m.stage IN ('beta'::scripts.stage, 'stable'::scripts.stage);
$$;

REVOKE ALL ON FUNCTION "payments"."average_price"() FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "payments"."average_price"() TO "authenticated", "service_role";
