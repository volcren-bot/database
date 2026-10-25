ALTER TABLE "payments"."payments"
  ADD COLUMN "amount" bigint NOT NULL;

ALTER TABLE "scripts"."metadata"
  ALTER COLUMN "price" DROP DEFAULT;

ALTER TABLE "scripts"."metadata"
  ALTER COLUMN "price" TYPE bigint USING "price"::bigint;

ALTER TABLE "scripts"."metadata"
  ALTER COLUMN "price" SET DEFAULT 0;

ALTER TABLE "payments"."payments"
  ADD CONSTRAINT "payments_amount_check" CHECK ((amount > 0));

ALTER TABLE "scripts"."metadata"
  ADD CONSTRAINT "metadata_price_max_check" CHECK ((price <= 10000));

COMMENT ON COLUMN "payments"."payments"."amount" IS 'Amount paid, in the minor unit of currency (cents for EUR). Separate from credits so bonuses and other currencies stay possible.';

COMMENT ON COLUMN "payments"."payments"."credits" IS 'Credits granted when the payment settles.';

COMMENT ON COLUMN "scripts"."metadata"."price" IS 'Credits (1 credit = 0.01 cent EUR, 10,000 credits = 1 EUR) charged per minute of use. 0 for free scripts, 1 to 10,000 for premium ones. The maximum is a constant because a CHECK can''t read payments.config.';
