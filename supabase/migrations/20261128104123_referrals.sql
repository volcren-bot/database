SET local check_function_bodies = off;

CREATE TABLE "payments"."referrals" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "referrer"        uuid                     NOT NULL,
  "invitee"         uuid                     NOT NULL,
  "discord_hash"    bytea                    NOT NULL,
  "eligible"        boolean                  NOT NULL,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "gift_at"         timestamp with time zone,
  "runtime_scripts" uuid[]                   NOT NULL DEFAULT '{}'::uuid[],
  "invites"         integer                  NOT NULL DEFAULT 0,
  "topped_up"       boolean                  NOT NULL DEFAULT false,
  "earned"          bigint                   NOT NULL DEFAULT 0,
  CONSTRAINT "referrals_discord_hash_key" UNIQUE (discord_hash),
  CONSTRAINT "referrals_invitee_key" UNIQUE (invitee),
  CONSTRAINT "referrals_pkey" PRIMARY KEY (id),
  CONSTRAINT "referrals_progress_check" CHECK (((invites >= 0) AND (earned >= 0))),
  CONSTRAINT "referrals_self_check" CHECK ((referrer <> invitee))
);

ALTER TABLE "payments"."referrals"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "payments"."config"
  ADD COLUMN "referral_gift" bigint NOT NULL DEFAULT 500000;

ALTER TABLE "payments"."config"
  ADD COLUMN "referral_runtime_reward" bigint NOT NULL DEFAULT 250000;

ALTER TABLE "payments"."config"
  ADD COLUMN "referral_runtime_scripts" integer NOT NULL DEFAULT 4;

ALTER TABLE "payments"."config"
  ADD COLUMN "referral_runtime_minutes" integer NOT NULL DEFAULT 120;

ALTER TABLE "payments"."config"
  ADD COLUMN "referral_runtime_days" integer NOT NULL DEFAULT 2;

ALTER TABLE "payments"."config"
  ADD COLUMN "referral_invite_reward" bigint NOT NULL DEFAULT 100000;

ALTER TABLE "payments"."config"
  ADD COLUMN "referral_invites" integer NOT NULL DEFAULT 10;

ALTER TABLE "payments"."config"
  ADD COLUMN "referral_topup_reward" bigint NOT NULL DEFAULT 1000000;

ALTER TABLE "payments"."config"
  ADD COLUMN "referral_min_discord_days" integer NOT NULL DEFAULT 30;

ALTER TABLE "profiles"."profiles"
  ADD COLUMN "referral_code" text NOT NULL DEFAULT encode(extensions.gen_random_bytes(6), 'hex'::text);

ALTER TYPE "payments"."credit_kind" ADD VALUE 'referral' AFTER 'adjustment';



CREATE OR REPLACE FUNCTION payments.claim_referral (
  p_code text
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_referrer uuid;
  v_discord_id text;
  v_hash bytea;
  v_created timestamptz;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT p.id INTO v_referrer FROM profiles.profiles p
  WHERE p.referral_code = lower(btrim(COALESCE(p_code, ''))) AND p.banned_at IS NULL;

  IF v_referrer IS NULL THEN
    RETURN 'invalid';
  END IF;

  IF v_referrer = v_user THEN
    RETURN 'own';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('payments.referrals.' || v_user::text));

  IF EXISTS (SELECT 1 FROM payments.referrals r WHERE r.invitee = v_user) THEN
    RETURN 'already_referred';
  END IF;

  IF EXISTS (SELECT 1 FROM payments.referrals r WHERE r.referrer = v_user AND r.invitee = v_referrer) THEN
    RETURN 'own';
  END IF;

  IF profiles.is_banned(v_user)
     OR EXISTS (SELECT 1 FROM payments.sessions s WHERE s.user_id = v_user)
     OR EXISTS (SELECT 1 FROM payments.agent_sessions s WHERE s.user_id = v_user)
     OR EXISTS (SELECT 1 FROM payments.payments p WHERE p.user_id = v_user) THEN
    RETURN 'not_new';
  END IF;

  SELECT i.provider_id INTO v_discord_id FROM auth.identities i
  WHERE i.user_id = v_user AND i.provider = 'discord' AND i.provider_id ~ '^[0-9]{1,19}$'
  LIMIT 1;

  SELECT extensions.hmac(v_discord_id, s.decrypted_secret, 'sha256') INTO v_hash
  FROM vault.decrypted_secrets s WHERE s.name = 'REFERRAL_SECRET' LIMIT 1;

  IF v_hash IS NULL THEN
    RETURN 'unavailable';
  END IF;

  IF EXISTS (SELECT 1 FROM payments.referrals r WHERE r.discord_hash = v_hash) THEN
    RETURN 'already_referred';
  END IF;

  v_created := to_timestamp(((v_discord_id::bigint >> 22) + 1420070400000) / 1000.0);

  INSERT INTO payments.referrals (referrer, invitee, discord_hash, eligible)
  VALUES (v_referrer, v_user, v_hash,
          v_created <= now() - make_interval(days => (SELECT c.referral_min_discord_days FROM payments.config c)));

  RETURN 'claimed';
END;
$function$;

CREATE OR REPLACE FUNCTION payments.grant_referral_gift (
  p_user uuid
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_referral payments.referrals;
  v_paid bigint;
BEGIN
  SELECT * INTO v_referral FROM payments.referrals r WHERE r.invitee = p_user FOR UPDATE;

  IF NOT FOUND OR NOT v_referral.eligible OR v_referral.gift_at IS NOT NULL
     OR profiles.is_banned(p_user) OR profiles.is_banned(v_referral.referrer) THEN
    RETURN 0;
  END IF;

  v_paid := payments.pay_referral(p_user, (SELECT c.referral_gift FROM payments.config c), 'welcome gift');
  UPDATE payments.referrals SET gift_at = now() WHERE id = v_referral.id;
  RETURN v_paid;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.list_referrals()
  RETURNS TABLE (
    id              uuid,
    created_at      timestamp with time zone,
    eligible        boolean,
    banned          boolean,
    runtime_scripts integer,
    invites         integer,
    topped_up       boolean,
    earned          bigint
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT r.id, r.created_at, r.eligible, profiles.is_banned(r.invitee), cardinality(r.runtime_scripts), r.invites, r.topped_up, r.earned
  FROM payments.referrals r
  WHERE r.referrer = auth.uid()
  ORDER BY r.created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION payments.own_referral()
  RETURNS TABLE (
    created_at timestamp with time zone,
    eligible   boolean,
    gift_at    timestamp with time zone
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
  SELECT r.created_at, r.eligible, r.gift_at FROM payments.referrals r WHERE r.invitee = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION payments.pay_referral (
  p_user   uuid,
  p_amount bigint,
  p_note   text
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
BEGIN
  IF p_amount <= 0 OR NOT EXISTS (SELECT 1 FROM payments.accounts a WHERE a.user_id = p_user) THEN
    RETURN 0;
  END IF;

  PERFORM payments.post_credits(p_user, 'referral', p_amount, NULL, NULL, NULL, p_note, NULL, NULL, p_amount);
  RETURN p_amount;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.reward_referral (
  p_invitee uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET row_security TO 'off'
  AS $function$
DECLARE
  v_config payments.config;
  v_referral payments.referrals;
  v_parent payments.referrals;
  v_qualified boolean;
  v_scripts uuid[];
  v_paid bigint;
BEGIN
  SELECT * INTO v_referral FROM payments.referrals r WHERE r.invitee = p_invitee FOR UPDATE;

  IF NOT FOUND OR NOT v_referral.eligible OR profiles.is_banned(v_referral.referrer) OR profiles.is_banned(p_invitee) THEN
    RETURN;
  END IF;

  SELECT * INTO v_config FROM payments.config;
  v_qualified := cardinality(v_referral.runtime_scripts) > 0 OR v_referral.topped_up;

  IF cardinality(v_referral.runtime_scripts) < v_config.referral_runtime_scripts THEN
    SELECT COALESCE(array_agg(q.script_id ORDER BY q.first_run), '{}'::uuid[]) INTO v_scripts
    FROM (
      SELECT s.script_id, min(s.started_at) AS first_run
      FROM payments.sessions s
      WHERE s.user_id = p_invitee AND s.author_id <> p_invitee AND s.ended_at IS NOT NULL
        AND s.script_id <> ALL (v_referral.runtime_scripts)
      GROUP BY s.script_id
      HAVING sum(s.charged_minutes) >= v_config.referral_runtime_minutes
         AND count(DISTINCT (s.started_at AT TIME ZONE 'UTC')::date) >= v_config.referral_runtime_days
      ORDER BY first_run
      LIMIT v_config.referral_runtime_scripts - cardinality(v_referral.runtime_scripts)
    ) q;

    IF cardinality(v_scripts) > 0 THEN
      v_paid := payments.pay_referral(v_referral.referrer, v_config.referral_runtime_reward * cardinality(v_scripts), 'an invitee kept running a script');
      UPDATE payments.referrals SET runtime_scripts = runtime_scripts || v_scripts, earned = earned + v_paid
      WHERE id = v_referral.id RETURNING * INTO v_referral;
    END IF;
  END IF;

  IF NOT v_referral.topped_up AND EXISTS (SELECT 1 FROM payments.payments p WHERE p.user_id = p_invitee AND p.status = 'paid'::payments.payment_status) THEN
    v_paid := payments.pay_referral(v_referral.referrer, v_config.referral_topup_reward, 'an invitee topped up');
    UPDATE payments.referrals SET topped_up = true, earned = earned + v_paid
    WHERE id = v_referral.id RETURNING * INTO v_referral;
  END IF;

  IF v_qualified OR NOT (cardinality(v_referral.runtime_scripts) > 0 OR v_referral.topped_up) THEN
    RETURN;
  END IF;

  SELECT * INTO v_parent FROM payments.referrals r WHERE r.invitee = v_referral.referrer FOR UPDATE;

  IF FOUND AND v_parent.eligible AND v_parent.invites < v_config.referral_invites AND NOT profiles.is_banned(v_parent.referrer) THEN
    v_paid := payments.pay_referral(v_parent.referrer, v_config.referral_invite_reward, 'an invitee''s invitee qualified');
    UPDATE payments.referrals SET invites = invites + 1, earned = earned + v_paid WHERE id = v_parent.id;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION payments.tr_referral_progress()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  PERFORM payments.reward_referral(NEW.user_id);
  RETURN NULL;
END;
$function$;

ALTER TABLE "payments"."config"
  ADD CONSTRAINT "config_referral_check"
    CHECK
    (((referral_gift >= 0) AND (referral_runtime_reward >= 0) AND (referral_invite_reward >= 0) AND (referral_topup_reward >= 0) AND (referral_runtime_scripts >= 0) AND
    (referral_invites >= 0) AND (referral_runtime_minutes > 0) AND (referral_runtime_days > 0) AND (referral_min_discord_days >= 0)));

ALTER TABLE "profiles"."profiles"
  ADD CONSTRAINT "profiles_referral_code_key" UNIQUE (referral_code);

CREATE INDEX referrals_referrer_idx ON payments.referrals USING btree (referrer, created_at DESC);

CREATE TRIGGER tr_payments_referral
  AFTER UPDATE OF status ON payments.payments
  FOR EACH ROW
  WHEN (((new.status = 'paid'::payments.payment_status) AND (old.status <> 'paid'::payments.payment_status)))
  EXECUTE FUNCTION payments.tr_referral_progress();

CREATE TRIGGER tr_sessions_referral
  AFTER UPDATE OF ended_at ON payments.sessions
  FOR EACH ROW
  WHEN (((old.ended_at IS NULL) AND (new.ended_at IS NOT NULL)))
  EXECUTE FUNCTION payments.tr_referral_progress();

REVOKE ALL ON FUNCTION "payments"."claim_referral"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."claim_referral"(text) TO "authenticated", "postgres";

REVOKE ALL ON FUNCTION "payments"."grant_referral_gift"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."grant_referral_gift"(uuid) TO "postgres", "service_role";

REVOKE ALL ON FUNCTION "payments"."list_referrals"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."list_referrals"() TO "authenticated", "postgres";

REVOKE ALL ON FUNCTION "payments"."own_referral"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."own_referral"() TO "authenticated", "postgres";

REVOKE ALL ON FUNCTION "payments"."pay_referral"(uuid, bigint, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."pay_referral"(uuid, bigint, text) TO "postgres";

REVOKE ALL ON FUNCTION "payments"."reward_referral"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."reward_referral"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "payments"."tr_referral_progress"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "payments"."tr_referral_progress"() TO "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "payments"."referrals" TO "postgres";

GRANT SELECT ON TABLE "payments"."referrals" TO "service_role";

