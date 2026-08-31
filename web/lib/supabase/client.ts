import { createBrowserClient } from "@supabase/ssr";

// Browser-side Supabase client. Only lib/supabase/* and lib/backend.ts should
// import @supabase/ssr or @supabase/supabase-js — everything else goes
// through lib/backend.ts so the rest of the app isn't coupled to Supabase.
export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
}
