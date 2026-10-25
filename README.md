# Volcren database

The Supabase backend for [Volcren](https://volcren.com): Postgres schema, migrations, tests, and the self-hosted stack that runs it.

## What's in the database

| Schema     | Contents |
|------------|----------|
| `public`   | HMAC helper and the signed `webhook()` trigger that notifies the webapp of row changes. |
| `profiles` | One profile per Discord user: username, avatar, role (`user` → `administrator`). No emails or provider IDs. |
| `scripts`  | Scripts, their metadata (stage, type, price), and revisions whose files live in the `scripts` storage bucket. |
| `payments` | Credit and earnings ledgers, cached balances, payments from providers, and per-minute usage sessions. |
| `stats`    | Per-user and per-script stats, sanity limits, online counts, website download tracking. |
| `info`     | Versioned legal documents (privacy policy, user ToS, scripter ToS). |
| `storage`  | RLS policies for the `scripts`, `imgs`, `assets` and `launcher` buckets. |

### Key ideas

- **Discord-only sign-in.** Sign-ups from any other provider are rejected, and OAuth emails are replaced with a synthetic `<id>@volcren.com` address.
- **Credits.** All money is in integer credits: 1 credit = 0.01 cent EUR, so 1 EUR = 10,000 credits. Premium scripts charge a price in credits per minute of use; authors earn the rest after the platform fee (`payments.config.platform_fee_bps`, 20% by default).
- **Usage sessions.** The API opens a session with `payments.start_session`, the loader sends heartbeats (`heartbeat_session`) which charge every elapsed minute, and the session ends on stop, timeout (pg_cron sweeps stale sessions every minute), or insufficient credits.
- **Revision lifecycle.** A script revision is created `pending`, its files are uploaded to `scripts/<id>/<9-digit revision>/`, and `scripts.publish_version` makes it `live` once every listed file exists.
- **Append-only ledgers.** Ledger rows can't be updated or deleted and deliberately don't reference profiles or scripts, so financial history survives deletions.

## Repository layout

```
supabase/
  schemas/        Declarative schema, one file per schema, applied in filename order
  migrations/     Migrations generated from the schemas (plus hand-written data steps)
  tests/database/ pgTAP tests
  config.toml     Supabase CLI config for the local stack
docker-compose.yml  Self-hosted Supabase stack (deployed with Coolify)
persistent_storage/ Files mounted into the containers, by service and container path
scheduled_tasks/    Coolify scheduled tasks (nightly schema sync, weekly log trim)
```

## Local development

Requires the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) and Docker.

```sh
supabase start      # start the local stack
supabase db reset   # recreate the database from migrations
supabase test db    # run the pgTAP tests
```

Discord login locally needs `SUPABASE_AUTH_EXTERNAL_DISCORD_CLIENT_ID` and `SUPABASE_AUTH_EXTERNAL_DISCORD_SECRET` in your environment.

### Changing the schema

1. Edit the relevant file in `supabase/schemas/`.
2. Generate a migration: `supabase db diff -f <name>`.
3. Add anything the diff can't capture by hand, such as bucket rows or `cron.schedule` calls.
4. Run `supabase db reset` and `supabase test db`.

Don't edit migrations that are already in production; add a new one instead.

## Deployment

The stack in `docker-compose.yml` runs on Coolify. The files under `persistent_storage/` are the contents of Coolify's file mounts, organised as `<service>/<path inside the container>`.

The `db-utils` container runs two scheduled tasks:

| Task | Schedule | What it does |
|------|----------|--------------|
| `sync` | daily, 03:00 | Dumps the live schema to `supabase/live_schema.sql`, pushes it to this repo if it changed, and fails if the applied migrations differ from `supabase/migrations/`. |
| `trim-logs` | weekly, Sunday 00:00 | Deletes old Logflare logs and vacuums the `_supabase` database. |

The webhook trigger reads `WEBHOOK_SECRET` and `WEBHOOK_BASE_URL` from Supabase Vault. When either is missing it does nothing, so local setups work without the webapp.
