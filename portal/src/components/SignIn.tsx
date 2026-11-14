import { useState } from "react";
import { supabase } from "../lib/api";
import { Notice, Snowflake, Spinner } from "./ui";

/// Email sign-in with a 6-digit code (the email also has a link).
export function SignIn({ title = "Sign in to Winter", subtitle }: { title?: string; subtitle?: string }) {
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [step, setStep] = useState<"email" | "code">("email");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function sendCode(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: { emailRedirectTo: window.location.href, shouldCreateUser: true },
    });
    setBusy(false);
    if (error) setError(error.message);
    else setStep("code");
  }

  async function verify(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { error } = await supabase.auth.verifyOtp({ email: email.trim(), token: code.trim(), type: "email" });
    setBusy(false);
    if (error) setError(error.message.includes("expired") ? "That code has expired or is wrong. Try again." : error.message);
  }

  return (
    <div className="glass mx-auto w-full max-w-md p-7 sm:p-8">
      <div className="mb-6 flex items-center gap-3">
        <span className="grid h-11 w-11 place-items-center rounded-2xl bg-sky-300/15 ring-1 ring-sky-200/30">
          <Snowflake className="h-5 w-5 text-sky-200" />
        </span>
        <div>
          <h1 className="text-xl font-semibold text-white">{title}</h1>
          <p className="text-sm text-slate-400">{subtitle ?? "We'll email you a sign-in code."}</p>
        </div>
      </div>

      {step === "email" ? (
        <form onSubmit={sendCode} className="space-y-4">
          <div>
            <label className="label" htmlFor="email">Email</label>
            <input id="email" type="email" required autoFocus autoComplete="email" className="input"
              placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
          </div>
          {error && <Notice tone="error">{error}</Notice>}
          <button className="btn-primary w-full" disabled={busy}>
            {busy ? <Spinner className="h-4 w-4" /> : "Email me a code"}
          </button>
        </form>
      ) : (
        <form onSubmit={verify} className="space-y-4">
          <Notice>Code sent to <b>{email}</b>. Check your inbox (and spam).</Notice>
          <div>
            <label className="label" htmlFor="code">6-digit code</label>
            <input id="code" inputMode="numeric" autoComplete="one-time-code" required autoFocus maxLength={6}
              className="input text-center text-2xl font-semibold tracking-[0.5em]" placeholder="••••••"
              value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))} />
          </div>
          {error && <Notice tone="error">{error}</Notice>}
          <button className="btn-primary w-full" disabled={busy || code.length < 6}>
            {busy ? <Spinner className="h-4 w-4" /> : "Sign in"}
          </button>
          <button type="button" className="w-full text-center text-sm text-slate-400 hover:text-white"
            onClick={() => { setStep("email"); setCode(""); setError(null); }}>
            Use a different email
          </button>
        </form>
      )}
    </div>
  );
}
