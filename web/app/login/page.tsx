"use client";

import { useActionState, useState } from "react";
import { signIn, signUp, type AuthActionState } from "./actions";

const initialState: AuthActionState = { error: null };

export default function LoginPage() {
  const [mode, setMode] = useState<"sign-in" | "sign-up">("sign-in");
  const [signInState, signInAction, signInPending] = useActionState(signIn, initialState);
  const [signUpState, signUpAction, signUpPending] = useActionState(signUp, initialState);

  const isSignIn = mode === "sign-in";
  const state = isSignIn ? signInState : signUpState;
  const pending = isSignIn ? signInPending : signUpPending;

  return (
    <main className="page" style={{ maxWidth: 380, paddingTop: "18vh" }}>
      <div className="stack">
        <div>
          <div className="brand">
            Pollux <span className="brand-accent">One</span>
          </div>
          <p className="subtitle" style={{ marginTop: 8 }}>
            Camera first. Teleprompter second. Write your script here, read it on your phone.
          </p>
        </div>

        <form action={isSignIn ? signInAction : signUpAction} className="stack card">
          <input className="input" type="email" name="email" placeholder="Email" required autoComplete="email" />
          <input
            className="input"
            type="password"
            name="password"
            placeholder="Password"
            required
            minLength={6}
            autoComplete={isSignIn ? "current-password" : "new-password"}
          />
          {state.error && <p className="error-text">{state.error}</p>}
          <button className="button" type="submit" disabled={pending}>
            {pending ? "…" : isSignIn ? "Sign in" : "Create account"}
          </button>
        </form>

        <button
          className="button button-secondary"
          type="button"
          onClick={() => setMode(isSignIn ? "sign-up" : "sign-in")}
        >
          {isSignIn ? "Need an account? Sign up" : "Have an account? Sign in"}
        </button>
      </div>
    </main>
  );
}
