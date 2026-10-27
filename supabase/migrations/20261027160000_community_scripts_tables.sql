SET local check_function_bodies = off;

DROP POLICY "INSERT for SCRIPTER" ON "scripts"."scripts";

DROP POLICY "INSERT for AUTHOR" ON "scripts"."versions";

DROP POLICY "SELECT for AUTHOR" ON "scripts"."versions";

DROP POLICY "scripts SELECT for author" ON "storage"."objects";

CREATE TABLE "info"."acceptances" (
  "user_id"     uuid                     NOT NULL,
  "version"     integer                  NOT NULL,
  "accepted_at" timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE "info"."acceptances"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "scripts"."config" (
  "id"                    boolean NOT NULL DEFAULT true,
  "max_community_scripts" integer NOT NULL DEFAULT 50,
  "max_community_bytes"   bigint  NOT NULL DEFAULT 31457280,
  "max_open_share_codes"  integer NOT NULL DEFAULT 20,
  "max_share_code_days"   integer NOT NULL DEFAULT 30,
  "redeem_max_failures"   integer NOT NULL DEFAULT 10,
  "redeem_window_minutes" integer NOT NULL DEFAULT 60,
  CONSTRAINT "config_check"
    CHECK
    (((max_community_scripts > 0) AND (max_community_bytes > 0) AND (max_open_share_codes > 0) AND (max_share_code_days > 0) AND (redeem_max_failures > 0) AND
    (redeem_window_minutes > 0))),
  CONSTRAINT "config_pkey" PRIMARY KEY (id),
  CONSTRAINT "config_singleton" CHECK (id)
);

ALTER TABLE "scripts"."config"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "scripts"."grants" (
  "script_id"  uuid                     NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "code_id"    uuid                     NOT NULL,
  "granted_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "grants_pkey" PRIMARY KEY (script_id, user_id)
);

ALTER TABLE "scripts"."grants"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "scripts"."redeem_attempts" (
  "user_id"      uuid                     NOT NULL,
  "attempted_at" timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE "scripts"."redeem_attempts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "scripts"."share_codes" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "script_id"   uuid                     NOT NULL,
  "code_hash"   text                     NOT NULL,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  "expires_at"  timestamp with time zone NOT NULL,
  "redeemed_by" uuid,
  "redeemed_at" timestamp with time zone,
  CONSTRAINT "share_codes_code_hash_check" CHECK ((code_hash ~ '^[0-9a-f]{64}$'::text)),
  CONSTRAINT "share_codes_code_hash_key" UNIQUE (code_hash),
  CONSTRAINT "share_codes_expires_check" CHECK ((expires_at > created_at)),
  CONSTRAINT "share_codes_pkey" PRIMARY KEY (id),
  CONSTRAINT "share_codes_redeemed_check" CHECK (((redeemed_by IS NULL) = (redeemed_at IS NULL))),
  "created_by"  uuid                     NOT NULL DEFAULT auth.uid()
);

ALTER TABLE "scripts"."share_codes"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "scripts"."versions"
  ADD COLUMN "sizes" bigint[] NOT NULL DEFAULT '{}'::bigint[];

ALTER TYPE "info"."kind" ADD VALUE 'community_tos' AFTER 'scripter_tos';

