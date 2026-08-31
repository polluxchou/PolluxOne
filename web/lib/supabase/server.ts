import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

// Server Component / Server Action Supabase client. `cookies()` is async in
// this Next.js version (16) — see node_modules/next/dist/docs/.../cookies.md.
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) => {
              cookieStore.set(name, value, options);
            });
          } catch {
            // Called from a Server Component render (not a Server Action /
            // Route Handler) — setting cookies there is a no-op by design.
            // proxy.ts refreshes the session on every request, so this is
            // safe to ignore.
          }
        },
      },
    }
  );
}
