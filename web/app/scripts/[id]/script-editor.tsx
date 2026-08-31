"use client";

import { useActionState } from "react";
import { saveScriptAction, type SaveState } from "./actions";

const initialState: SaveState = { savedAt: null, error: null };

export function ScriptEditor({
  id,
  initialTitle,
  initialBody,
  version,
}: {
  id: string;
  initialTitle: string;
  initialBody: string;
  version: number;
}) {
  const [state, formAction, pending] = useActionState(saveScriptAction.bind(null, id), initialState);

  return (
    <form action={formAction} className="stack" style={{ marginTop: 16 }}>
      <input
        className="input"
        name="title"
        defaultValue={initialTitle}
        style={{ fontSize: 22, fontWeight: 700, border: "none", padding: "8px 0", background: "transparent" }}
        required
      />

      <div>
        <label className="field-label" htmlFor="body">
          Script — blank line = new paragraph, period = new sentence
        </label>
        <textarea
          id="body"
          name="body"
          className="input"
          defaultValue={initialBody}
          rows={18}
          style={{ marginTop: 8, fontSize: 16 }}
        />
      </div>

      <div className="row">
        <span className="script-item-meta">
          v{version}
          {state.savedAt && ` · saved`}
          {state.error && <span className="error-text"> · {state.error}</span>}
        </span>
        <button className="button" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save"}
        </button>
      </div>
    </form>
  );
}
