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

