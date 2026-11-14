import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { SignIn } from "../components/SignIn";
import { Notice, Shell, Snowflake, Spinner } from "../components/ui";
import { ApiError, callApp } from "../lib/api";
import { useSession } from "../lib/session";

/// Opened by the desktop app ("Sign In…"): sign in, then approve the code so
/// the app on this computer receives its device token.
export function LinkPage() {
  const [params] = useSearchParams();
  const code = params.get("code") ?? "";
  const next = params.get("next");
  const { user, loading } = useSession();
  const navigate = useNavigate();
  const [state, setState] = useState<"idle" | "linking" | "done" | "expired" | "error">("idle");
  const started = useRef(false);

  useEffect(() => {
    if (!user || !code || started.current) return;
    started.current = true;
    setState("linking");
    callApp("/link/approve", { code })
      .then(() => {
        setState("done");
        if (next === "upgrade") setTimeout(() => navigate("/upgrade"), 1200);
      })
      .catch((e) => setState(e instanceof ApiError && e.status === 410 ? "expired" : "error"));
  }, [user, code, next, navigate]);

  return (
    <Shell>
      <div className="pt-10">
        {!code ? (
          <div className="mx-auto max-w-md"><Notice tone="error">This link is missing its code. Choose “Sign In…” in Winter again.</Notice></div>
        ) : loading ? (
          <div className="grid place-items-center py-24"><Spinner /></div>
        ) : !user ? (
          <SignIn title="Connect Winter" subtitle="Sign in to link Winter on this computer." />
        ) : (
          <div className="glass mx-auto max-w-md p-8 text-center">
            <span className="mx-auto mb-5 grid h-14 w-14 place-items-center rounded-2xl bg-sky-300/15 ring-1 ring-sky-200/30">
              {state === "linking" ? <Spinner className="h-6 w-6 text-sky-200" /> : <Snowflake className="h-7 w-7 text-sky-200" />}
            </span>
            {state === "linking" && <h1 className="text-xl font-semibold text-white">Connecting…</h1>}
            {state === "done" && (
              <>
                <h1 className="text-xl font-semibold text-white">Winter is connected</h1>
                <p className="mt-2 text-sm text-slate-400">
                  Signed in as {user.email}. {next === "upgrade" ? "Taking you to Winter Pro…" : "You can close this tab and go back to your desktop."}
                </p>
                {next !== "upgrade" && <Link to="/account" className="btn-ghost mt-6">View account</Link>}
              </>
            )}
            {state === "expired" && (
              <>
                <h1 className="text-xl font-semibold text-white">This link has expired</h1>
                <p className="mt-2 text-sm text-slate-400">Links work for 15 minutes and only once. Choose “Sign In…” in the Winter menu again.</p>
              </>
            )}
            {state === "error" && (
              <>
                <h1 className="text-xl font-semibold text-white">Something went wrong</h1>
                <p className="mt-2 text-sm text-slate-400">Please try “Sign In…” in Winter again.</p>
              </>
            )}
          </div>
        )}
      </div>
    </Shell>
  );
}
