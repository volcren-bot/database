# Volcren database

Self-hosted Supabase backend for Volcren (a script marketplace). Postgres schema in `supabase/`, deployment stack (Coolify) at the repo root.

## Schema workflow

`supabase/schemas/*.sql` is the declarative source of truth; `supabase/migrations/` is what actually runs.

1. Edit the schema file for the affected schema.
2. Generate a migration: `supabase db schema declarative sync --no-apply --name <snake_case_name>` (pg-delta engine, see `config.toml`; CLI 2.118's `db diff` only compares migrations with the database). Review the output: it can emit a `REVOKE ALL ON TABLE` that drops column-level grants and doesn't restore them, and it stamps the file with the current time, which can sort before existing migrations.
3. Hand-append anything the diff can't see, since it compares structure only: data rows (`storage.buckets`, the `scripts.config` row), `cron.schedule(...)` calls, and anything else that is a statement rather than an object. It does write `ALTER TYPE ... ADD VALUE` itself, in a migration of its own. Add a header comment saying why the migration exists.
4. `supabase db reset`, then `supabase test db`. Done when every pgTAP test passes and the reset applies cleanly.

Once a migration is in production, it is frozen: fix forward with a new migration. Nightly sync fails on any drift between `supabase/migrations/` filenames and `supabase_migrations.schema_migrations`.

Production is migrated by pasting files into the Supabase SQL editor, which does not record them. After pasting a migration, also run `insert into supabase_migrations.schema_migrations (version, name) values ('<timestamp>', '<name>');` (filename is `<timestamp>_<name>.sql`). Never put that insert inside the migration file: the CLI records versions itself, so the duplicate row would make `supabase db reset` fail. When handing the user a migration to apply, give them this insert alongside it.

## Conventions every function and table follows

- Schema files apply in filename order (`00_extensions` → `07_storage`). Cross-schema references at call time are fine (`scripts.can_access` reads `payments.accounts`); at definition time they are not.
- Every function: `SET "search_path" TO ''` and fully qualified names (`extensions.hmac`, `auth.uid()`).
- Functions are executable by `PUBLIC` by default. After defining one, `REVOKE ALL ... FROM PUBLIC, "anon", "authenticated"` and grant back only the roles that need it. RLS helpers (`profiles.min_role`, `profiles.uid`, ...) must stay granted to `anon`, since policies call them for anonymous visitors.
- Session functions (`payments.start_session`, `heartbeat_session`, `end_session`) are `service_role` only: the API calls them, never clients.
- Roles (`profiles.roles`) and stages (`scripts.stage`) are ordered enums compared with `>=`/`<=`. Insert new values in rank order.
- Money is integer **credits**: 1 credit = 0.01 cent EUR, 10,000 credits = 1 EUR. Script prices are credits per minute.
- `payments.*_ledger` tables are append-only (a trigger blocks UPDATE/DELETE) and have no FKs to profiles/scripts on purpose: financial history outlives accounts. Write balances only through `payments.post_credits` / `post_earnings`.

## Community scripts, share codes and terms

- **Official or community is derived, not stored**: a script is community while its author's role is below `scripter` (`scripts.author_is_community`). `tr_profiles_role_change` keeps the data in line: promotion to scripter+ unpublishes the author's scripts, demotion forces them free, and a scripter demoted to `user` who still has scripts lands on `contributor`. `tr_scripts_post_insert` promotes `user` → `contributor` on a first script; `tr_protected_post_delete` reverts it when the last one goes. Only moderator+ delete scripts (RLS `DELETE`; the webapp also removes the storage files through the Storage API).
- **Visibility** lives in `scripts.can_view` / `can_access`: moderator+ always; nobody else when the author is banned; then the author and grantees; community scripts are then tester+ only (stages and `published` are labels); official ones follow stage and published. A grant bypasses stage, published and archived and makes premium free (`payments.start_session` sets price 0). `can_access` still needs a live revision. `heartbeat_session` ends sessions on a banned author's scripts. Tester+ read community files through the `scripts.versions` and storage SELECT policies (`scripts.is_reviewable`).
- **Limits** are in the singleton `scripts.config`: scripts per community author (checked in `tr_scripts_post_insert` under an advisory lock, since a policy can't serialise inserts), storage bytes, open codes per script, the longest code expiry, and the redeem failure limit. Storage counts the real object sizes in the `scripts` bucket (`scripts.storage_used`): `tr_versions_pre_insert` requires `versions.sizes` from community authors and reserves them, and `publish_version` re-checks the real sizes. The `imgs` bucket is not counted. Moderator uploads count against the author.
- **Terms**: `info.acceptances` records the version a user accepted, written only by `info.accept_terms` (current version only). `profiles.has_accepted_terms` gates script creation, revision insert, `can_upload`, `publish_version`, deploy tokens and code creation, for every role. A kind with no published document asks nothing of scripter+, but community authors can't pass until both `scripter_tos` and `community_tos` exist. A new version of either asks everyone again; existing scripts keep running.
- **Share codes**: `scripts.create_share_code` generates the code in the database (32 CSPRNG bytes, hex), returns it once and stores only its SHA-256. Author or moderator+, not banned, terms accepted, expiry within the config limit, at most the configured open codes. `scripts.redeem_share_code` locks the code's row and marks it used and adds the grant in one transaction, so a code can't work twice. It returns a status instead of raising, because a raised error would roll back the failed attempt that the per-account rate limit counts (`scripts.redeem_attempts`). A redeemer who already sees the script, or wrote it, is refused and the code stays unused. Revoke unused codes by deleting them; revoke or remove grants by deleting the grant (author, moderator+ or the holder). `scripts.list_grantees` is the only way to see usernames. `scripts.delete_expired_share_codes` runs hourly from pg_cron (`00_extensions.sql`).
- `supabase/tests/concurrency/redeem_race.sh` races one code across parallel sessions against the local database. pgTAP can't, since it runs in one transaction.

## Privacy rules

- Discord is the only login. `profiles.require_discord` rejects every other provider at insert.
- No emails stored: triggers rewrite `auth.users.email` to `<id>@volcren.com` and strip `email` from identity data. Discord IDs live only in `auth.identities`, read through `profiles.get_provider_id`.

## Tests

pgTAP in `supabase/tests/database/`. Each file: `BEGIN; ... plan(n); ... finish(); ROLLBACK;`. Create users by inserting into `auth.users` with `raw_app_meta_data = '{"provider":"discord"}'` (copy `pg_temp.signup` from an existing test). Act as a client with `SET LOCAL ROLE authenticated` plus `set_config('request.jwt.claims', ...)`. Keep `plan(n)` equal to the assertion count.

## Deployment files

- `docker-compose.yml` is the Coolify service definition (`SERVICE_PASSWORD_*` / `SERVICE_URL_*` are Coolify magic variables).
- `persistent_storage/<service>/<container path>` mirrors the files Coolify mounts into each container: edit there, then paste into Coolify.
- `scheduled_tasks/*.txt` record the Coolify scheduled tasks that run in `db-utils`.
- `db-utils/.../sync.sh` dumps the live schema to `supabase/live_schema.sql` nightly. When you add a schema, add it to the `dump` list there. The dump aborts if it matches `secret|api_key|password|token|key_id` outside its allowlist, so a new column or comment using those words needs an allowlist entry.
- Secrets never go in SQL: the webhook reads `WEBHOOK_SECRET` / `WEBHOOK_BASE_URL` from the vault.
- `.env*` files hold real credentials; leave them unread.
