import type { SupabaseClient } from "@supabase/supabase-js";
import { bodyTextToParagraphs, type Script } from "./types";

// The only module (besides lib/supabase/*) that talks to Supabase directly.
// Server Actions and Server Components call these functions rather than
// querying Supabase themselves, so the storage layer can be swapped later
// without touching every call site — mirrors BackendClient on iOS.

type ScriptRow = {
  id: string;
  title: string;
  version: number;
  created_at: string;
  updated_at: string;
};

export async function listScripts(supabase: SupabaseClient): Promise<Script[]> {
  const { data, error } = await supabase
    .from("scripts")
    .select("id, title, version, created_at, updated_at")
    .order("updated_at", { ascending: false });

  if (error) throw error;

  return (data as ScriptRow[]).map((row) => ({
    id: row.id,
    title: row.title,
    version: row.version,
    sections: [],
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }));
}

export async function getScript(supabase: SupabaseClient, id: string): Promise<Script> {
  const { data, error } = await supabase
    .from("scripts")
    .select(
      `id, title, version, created_at, updated_at,
       script_sections (
         id, title, sort_order,
         paragraphs (
           id, sort_order,
           sentences ( id, sort_order, text )
         )
       )`
    )
    .eq("id", id)
    .single();

  if (error) throw error;

  const row = data as unknown as ScriptRow & {
    script_sections: {
      id: string;
      title: string | null;
      sort_order: number;
      paragraphs: {
        id: string;
        sort_order: number;
        sentences: { id: string; sort_order: number; text: string }[];
      }[];
    }[];
  };

  return {
    id: row.id,
    title: row.title,
    version: row.version,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    sections: [...row.script_sections]
      .sort((a, b) => a.sort_order - b.sort_order)
      .map((section) => ({
        id: section.id,
        title: section.title,
        order: section.sort_order,
        paragraphs: [...section.paragraphs]
          .sort((a, b) => a.sort_order - b.sort_order)
          .map((paragraph) => ({
            id: paragraph.id,
            order: paragraph.sort_order,
            sentences: [...paragraph.sentences]
              .sort((a, b) => a.sort_order - b.sort_order)
              .map((sentence) => ({ id: sentence.id, order: sentence.sort_order, text: sentence.text })),
          })),
      })),
  };
}

export async function createScript(supabase: SupabaseClient, title: string): Promise<string> {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) throw new Error("Not authenticated");

  const { data, error } = await supabase
    .from("scripts")
    .insert({ title, user_id: user.id })
    .select("id")
    .single();

  if (error) throw error;
  return (data as { id: string }).id;
}

export async function deleteScript(supabase: SupabaseClient, id: string): Promise<void> {
  const { error } = await supabase.from("scripts").delete().eq("id", id);
  if (error) throw error;
}

// Replaces the whole section/paragraph/sentence tree for a script. Simple
// and correct beats incremental diffing for a V1 whose only editor is one
// flat textarea — see bodyTextToParagraphs for the paragraph/sentence split.
export async function saveScriptBody(
  supabase: SupabaseClient,
  id: string,
  title: string,
  bodyText: string
): Promise<void> {
  const { error: titleError } = await supabase.from("scripts").update({ title }).eq("id", id);
  if (titleError) throw titleError;

  const { error: deleteError } = await supabase.from("script_sections").delete().eq("script_id", id);
  if (deleteError) throw deleteError;

  const paragraphs = bodyTextToParagraphs(bodyText);
  if (paragraphs.length === 0) return;

  const { data: section, error: sectionError } = await supabase
    .from("script_sections")
    .insert({ script_id: id, sort_order: 0 })
    .select("id")
    .single();
  if (sectionError) throw sectionError;

  for (const [paragraphIndex, sentences] of paragraphs.entries()) {
    const { data: paragraph, error: paragraphError } = await supabase
      .from("paragraphs")
      .insert({ section_id: (section as { id: string }).id, sort_order: paragraphIndex })
      .select("id")
      .single();
    if (paragraphError) throw paragraphError;

    const { error: sentencesError } = await supabase.from("sentences").insert(
      sentences.map((text, sentenceIndex) => ({
        paragraph_id: (paragraph as { id: string }).id,
        sort_order: sentenceIndex,
        text,
      }))
    );
    if (sentencesError) throw sentencesError;
  }
}
