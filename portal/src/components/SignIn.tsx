import { GoogleAuthProvider, sendSignInLinkToEmail, signInWithPopup } from "firebase/auth";
import { useState } from "react";
import { auth } from "../lib/api";
import { EMAIL_KEY, useSession } from "../lib/session";
import { Notice, Snowflake, Spinner } from "./ui";

/// "Continue with Google", or a sign-in link by email (no passwords).
export function SignIn({ title = "Sign in to Winter", subtitle }: { title?: string; subtitle?: string }) {
  const { needsEmailForLink, linkError, completeEmailLink } = useSession();
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState<"google" | "email" | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function google() {
    setBusy("google");
    setError(null);
    try {
      await signInWithPopup(auth, new GoogleAuthProvider());
    } catch (e) {
      const code = (e as { code?: string }).code ?? "";
      if (!code.includes("popup-closed") && !code.includes("cancelled-popup")) {
        setError(code.includes("popup-blocked") ? "Your browser blocked the sign-in window. Allow pop-ups and try again." : String(e));
      }
    } finally {
      setBusy(null);
    }
  }

  async function sendLink(e: React.FormEvent) {
    e.preventDefault();
    setBusy("email");
    setError(null);
    try {
      const address = email.trim();
      // The link brings the user back to this exact page (keeps ?code=… for the app).
      await sendSignInLinkToEmail(auth, address, { url: window.location.href, handleCodeInApp: true });
      try { localStorage.setItem(EMAIL_KEY, address); } catch { /* private mode */ }
      setSent(true);
    } catch (e) {
      const code = (e as { code?: string }).code ?? "";
      setError(code.includes("invalid-email") ? "That doesn't look like an email address." : String(e));
    } finally {
      setBusy(null);
    }
  }

  async function confirm(e: React.FormEvent) {
    e.preventDefault();
    setBusy("email");
    await completeEmailLink(email);
    setBusy(null);
  }

  return (
    <div className="glass mx-auto w-full max-w-md p-7 sm:p-8">
      <div className="mb-6 flex items-center gap-3">
        <span className="grid h-11 w-11 place-items-center rounded-2xl bg-sky-300/15 ring-1 ring-sky-200/30">
          <Snowflake className="h-5 w-5 text-sky-200" />
        </span>
        <div>
          <h1 className="text-xl font-semibold text-white">{needsEmailForLink ? "Confirm your email" : title}</h1>
          <p className="text-sm text-slate-400">
            {needsEmailForLink ? "You opened the sign-in link on another browser." : subtitle ?? "No password needed."}
          </p>
        </div>
      </div>

      {needsEmailForLink ? (
        <form onSubmit={confirm} className="space-y-4">
          <div>
            <label className="label" htmlFor="email">Email the link was sent to</label>
            <input id="email" type="email" required autoFocus className="input" value={email} onChange={(e) => setEmail(e.target.value)} />
          </div>
          {linkError && <Notice tone="error">{linkError}</Notice>}
          <button className="btn-primary w-full" disabled={busy !== null}>
            {busy ? <Spinner className="h-4 w-4" /> : "Continue"}
          </button>
        </form>
      ) : sent ? (
        <div className="space-y-4">
          <Notice tone="success">
            We sent a sign-in link to <b>{email}</b>. Open it in this browser to continue — you can close this tab.
          </Notice>
          <p className="text-xs text-slate-500">Not there? Check spam, or wait a minute.</p>
          <button className="w-full text-center text-sm text-slate-400 hover:text-white" onClick={() => setSent(false)}>
            Use a different email
          </button>
        </div>
      ) : (
        <div className="space-y-5">
          <button onClick={google} disabled={busy !== null}
            className="btn w-full border border-white/15 bg-white text-slate-900 hover:bg-slate-100">
            {busy === "google" ? <Spinner className="h-4 w-4" /> : <GoogleLogo />}
            Continue with Google
          </button>
          <div className="flex items-center gap-3 text-xs uppercase tracking-wider text-slate-500">
            <span className="h-px flex-1 bg-white/10" />or<span className="h-px flex-1 bg-white/10" />
          </div>
          <form onSubmit={sendLink} className="space-y-3">
            <div>
              <label className="label" htmlFor="email">Email</label>
              <input id="email" type="email" required autoComplete="email" className="input"
                placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
            <button className="btn-ghost w-full" disabled={busy !== null}>
              {busy === "email" ? <Spinner className="h-4 w-4" /> : "Email me a sign-in link"}
            </button>
          </form>
          {(error || linkError) && <Notice tone="error">{error ?? linkError}</Notice>}
        </div>
      )}
    </div>
  );
}

function GoogleLogo() {
  return (
    <svg viewBox="0 0 48 48" className="h-4.5 w-4.5" aria-hidden>
      <path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z" />
      <path fill="#FF3D00" d="M6.3 14.7l6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z" />
      <path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z" />
      <path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z" />
    </svg>
  );
}
