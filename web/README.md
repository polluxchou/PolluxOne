# Pollux One — Web

Script authoring console: sign in, create/edit scripts, sync down to iOS.
This is the primary place scripts get written — the iOS app is read-mostly
(see the root [README](../README.md) for the full product picture).

## Stack

Next.js 16 (App Router, Server Actions) + React 19 + Supabase (`@supabase/ssr`).
No CSS framework — plain `app/globals.css`.

`lib/backend.ts` is the only module that queries Supabase directly; pages and
Server Actions call it rather than importing `@supabase/supabase-js`
themselves, so storage can be swapped later without touching call sites.

> This repo pins Next.js 16, which renamed `middleware.ts` → `proxy.ts` and
> made `cookies()` async. If something here looks off versus a Next.js
> tutorial you remember, check `node_modules/next/dist/docs/` first — see the
> note `next dev` writes into `AGENTS.md`.

## Running it

```bash
cp .env.local.example .env.local   # fill in your Supabase project URL + anon key
npm install
npm run dev
```

Without real Supabase credentials the app still builds and every page
renders (auth calls fail with a visible "fetch failed" instead of crashing),
which is enough to check layout/UX but not to actually sign in.

Apply `../backend/supabase/migrations/0001_init.sql` to your Supabase
project before testing sign-up/script CRUD end to end.
