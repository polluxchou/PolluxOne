"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createScript, deleteScript } from "@/lib/backend";

export async function createScriptAction(formData: FormData) {
  const title = String(formData.get("title") ?? "").trim() || "Untitled script";
  const supabase = await createClient();
  const id = await createScript(supabase, title);
  redirect(`/scripts/${id}`);
}

export async function deleteScriptAction(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const supabase = await createClient();
  await deleteScript(supabase, id);
  revalidatePath("/scripts");
}

export async function signOutAction() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}
