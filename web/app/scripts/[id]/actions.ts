"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { saveScriptBody } from "@/lib/backend";

export type SaveState = { savedAt: number | null; error: string | null };

export async function saveScriptAction(
  id: string,
  _prevState: SaveState,
  formData: FormData
): Promise<SaveState> {
  const title = String(formData.get("title") ?? "").trim() || "Untitled script";
  const body = String(formData.get("body") ?? "");

  const supabase = await createClient();
  try {
    await saveScriptBody(supabase, id, title, body);
  } catch (err) {
    return { savedAt: null, error: err instanceof Error ? err.message : "Failed to save" };
  }

  revalidatePath("/scripts");
  revalidatePath(`/scripts/${id}`);
  return { savedAt: Date.now(), error: null };
}
