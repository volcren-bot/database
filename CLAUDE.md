# Volcren database

Self-hosted Supabase backend for Volcren (a script marketplace). Postgres schema in `supabase/`, deployment stack (Coolify) at the repo root.

## Schema workflow

`supabase/schemas/*.sql` is the declarative source of truth; `supabase/migrations/` is what actually runs.

1. Edit the schema file for the affected schema.
2. Generate a migration: `supabase db diff -f <snake_case_name>` (pg-delta engine, see `config.toml`).
3. Hand-append anything the diff can't see, since it compares structure only: data rows (`storage.buckets`), `cron.schedule(...)` calls, and anything else that is a statement rather than an object. Add a header comment saying why the migration exists.
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
