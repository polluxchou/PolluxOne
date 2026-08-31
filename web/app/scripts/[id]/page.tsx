import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getScript } from "@/lib/backend";
import { scriptToBodyText } from "@/lib/types";
import { ScriptEditor } from "./script-editor";

export default async function ScriptPage(props: PageProps<"/scripts/[id]">) {
  const { id } = await props.params;

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const script = await getScript(supabase, id);

  return (
    <main className="page">
      <Link href="/scripts" className="subtitle" style={{ textDecoration: "none" }}>
        ← All scripts
      </Link>
      <ScriptEditor
        id={script.id}
        initialTitle={script.title}
        initialBody={scriptToBodyText(script)}
        version={script.version}
      />
    </main>
  );
}
