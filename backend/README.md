# Pollux One — Backend

Supabase project schema for Pollux One: Auth (built-in) + Postgres schema
below + the auto-generated REST/Realtime API. Both `web/` and `ios/` talk to
this through their own thin backend-client abstraction (`lib/backend.ts` on
Web, `BackendClient` on iOS) — nothing above that layer references the
Supabase SDK directly, so a self-hosted API could replace this without
touching either client's call sites.

## Schema

See [`supabase/migrations/0001_init.sql`](supabase/migrations/0001_init.sql).
Mirrors the domain model in `ios/Pollux One/Domain`:

```
scripts
  └─ script_sections
       └─ paragraphs
            └─ sentences

recording_sessions (freezes script_id + script_version at take start)
  └─ reading_sessions   (live ReadingPosition/progress for that take)
  └─ voice_commands     (Safe Word → Voice Command Engine audit trail)

script_reading_progress   (last-known progress per script, for the Web list)
devices                   (iOS clients that have synced scripts)
profiles                  (auth.users mirror, created by trigger on signup)
```

Every table is scoped with row-level security to `auth.uid()`, either
directly (`user_id` column) or by joining up to the owning script/session —
a user only ever sees their own data. `script_sections` changing bumps
`scripts.version` via a trigger, which is what lets an in-progress iOS
`RecordingSession` (which freezes a version at start) detect that the Web
copy has since moved on.

## Running it

1. Create a Supabase project (or run `supabase start` locally with the
   Supabase CLI).
2. Apply the migration:
   ```bash
   supabase db push
   # or, against a local/dev Postgres directly:
   psql "$DATABASE_URL" -f supabase/migrations/0001_init.sql
   ```
3. Copy the project URL + anon key into `web/.env.local` (see
   `web/.env.local.example`) and into the iOS `SupabaseBackendClient` once
   that's wired up (see `ios/Pollux One/Networking/BackendClient.swift`).

The migration was validated locally against a scratch Postgres 17 instance
with a stubbed `auth` schema (not committed) — insert/trigger behavior for
the full script tree and the version-bump trigger were exercised directly.
