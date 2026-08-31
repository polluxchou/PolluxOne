import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { listScripts } from "@/lib/backend";
import { createScriptAction, deleteScriptAction, signOutAction } from "./actions";

export default async function ScriptsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const scripts = await listScripts(supabase);

  return (
    <main className="page">
      <div className="row" style={{ marginBottom: 32 }}>
        <div className="brand">
          Pollux <span className="brand-accent">One</span>
        </div>
        <form action={signOutAction}>
          <button className="button button-secondary" type="submit">
            Sign out
          </button>
        </form>
      </div>

      <h1>Scripts</h1>
      <p className="subtitle">
        Write here, then open Pollux One on your iPhone to record while reading it near the lens.
      </p>

      <form action={createScriptAction} className="row" style={{ marginBottom: 24 }}>
        <input className="input" name="title" placeholder="New script title…" required />
        <button className="button" type="submit" style={{ whiteSpace: "nowrap" }}>
          + New
        </button>
      </form>

      {scripts.length === 0 ? (
        <p className="empty-state">No scripts yet — create your first one above.</p>
      ) : (
        <div className="stack">
          {scripts.map((script) => (
            <div key={script.id} className="row" style={{ gap: 8 }}>
              <Link href={`/scripts/${script.id}`} className="script-item" style={{ flex: 1 }}>
                <p className="script-item-title">{script.title}</p>
                <p className="script-item-meta">
                  v{script.version} · updated {new Date(script.updatedAt).toLocaleDateString()}
                </p>
              </Link>
              <form action={deleteScriptAction}>
                <input type="hidden" name="id" value={script.id} />
                <button className="button button-danger" type="submit">
                  Delete
                </button>
              </form>
            </div>
          ))}
        </div>
      )}
    </main>
  );
}
