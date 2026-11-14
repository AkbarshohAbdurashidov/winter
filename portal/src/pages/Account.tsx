import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { SignIn } from "../components/SignIn";
import { AccessBadge, Notice, Shell, Spinner } from "../components/ui";
import { callApp, formatDate, timeAgo, type AccountInfo } from "../lib/api";
import { useSession } from "../lib/session";

const productName: Record<string, string> = { lifetime: "Lifetime", yearly: "Yearly", monthly: "Monthly" };

export function useAccount() {
  const { user } = useSession();
  const [info, setInfo] = useState<AccountInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async (refresh = false) => {
    if (!user) return;
    try {
      setInfo(await callApp<AccountInfo>("/account", { refresh }));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [user]);
  useEffect(() => { load(); }, [load]);
  return { info, error, reload: load };
}

export function AccountPage() {
  const { user, loading } = useSession();
  const { info, error, reload } = useAccount();
  const [refreshing, setRefreshing] = useState(false);

  if (loading) return <Shell><div className="grid place-items-center py-24"><Spinner /></div></Shell>;
  if (!user) return <Shell><div className="pt-10"><SignIn /></div></Shell>;

  async function refresh() {
    setRefreshing(true);
    await reload(true);
    setRefreshing(false);
  }

  async function revoke(hash: string) {
    await callApp("/devices/revoke", { tokenHash: hash });
    reload();
  }

  return (
    <Shell>
      <div className="mx-auto max-w-3xl space-y-6 pt-4">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <p className="text-sm text-slate-400">Signed in as</p>
            <h1 className="text-2xl font-semibold text-white">{user.email}</h1>
          </div>
          {info?.isAdmin && <Link to="/admin" className="btn-ghost">Open admin panel →</Link>}
        </div>

        {error && <Notice tone="error">Couldn't load your account: {error}</Notice>}
        {!info && !error && <div className="grid place-items-center py-16"><Spinner /></div>}

        {info && (
          <>
            <section className="glass overflow-hidden">
              <div className="relative p-6 sm:p-8">
                <div className="pointer-events-none absolute -right-20 -top-20 h-64 w-64 rounded-full bg-sky-400/10 blur-3xl" />
                <div className="flex flex-wrap items-start justify-between gap-4">
                  <div>
                    <p className="label">Winter Pro</p>
                    <div className="flex items-center gap-3">
                      <h2 className="text-3xl font-bold text-white">{info.pro ? "Active" : "Not active"}</h2>
                      <AccessBadge access={info.access} />
                    </div>
                    <p className="mt-2 text-sm text-slate-400">
                      {info.access === "free" && (info.expiresAt ? `Free access until ${formatDate(info.expiresAt)}.` : "You have free access. Enjoy!")}
                      {info.access === "lifetime" && "Lifetime purchase — yours forever."}
                      {(info.access === "trial" || info.access === "active") && (
                        <>
                          {productName[info.productId ?? ""] ?? info.productId} plan ·{" "}
                          {info.willRenew === false ? "ends" : info.access === "trial" ? "trial ends, then renews" : "renews"}{" "}
                          {formatDate(info.expiresAt)}
                        </>
                      )}
                      {(info.access === "none" || info.access === "expired" || info.access === "refunded") &&
                        "Heavy snowfall, blizzards and the highest quality settings come with Winter Pro."}
                    </p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    {!info.pro && <Link to="/upgrade" className="btn-primary">Get Winter Pro</Link>}
                    {info.manageUrl && info.access !== "free" && (
                      <a href={info.manageUrl} target="_blank" rel="noreferrer" className="btn-ghost">Manage subscription</a>
                    )}
                    <button onClick={refresh} className="btn-ghost" disabled={refreshing}>
                      {refreshing ? <Spinner className="h-4 w-4" /> : "Refresh"}
                    </button>
                  </div>
                </div>
              </div>
              {info.manageUrl && info.access !== "free" && (
                <div className="border-t border-white/5 bg-white/[0.02] px-6 py-3 text-xs text-slate-400 sm:px-8">
                  Cancel, change plan, update your card or download receipts in the customer portal.
                </div>
              )}
            </section>

            <section className="glass p-6 sm:p-8">
              <div className="mb-4 flex items-center justify-between">
                <h3 className="font-semibold text-white">Signed-in computers</h3>
                <span className="text-xs text-slate-500">{info.devices.length} active</span>
              </div>
              {info.devices.length === 0 ? (
                <p className="text-sm text-slate-400">
                  No computers yet. In Winter, open the ❄ menu and choose <b>Sign In…</b>
                </p>
              ) : (
                <ul className="divide-y divide-white/5">
                  {info.devices.map((d) => (
                    <li key={d.token_hash} className="flex items-center justify-between gap-3 py-3">
                      <div>
                        <p className="text-sm font-medium text-slate-100">{d.platform === "windows" ? "Windows PC" : d.platform === "macos" ? "Mac" : "Computer"}</p>
                        <p className="text-xs text-slate-500">Linked {formatDate(d.created_at)} · last seen {timeAgo(d.last_seen)}</p>
                      </div>
                      <button className="btn-ghost !py-1.5 text-xs" onClick={() => revoke(d.token_hash)}>Sign out</button>
                    </li>
                  ))}
                </ul>
              )}
            </section>
          </>
        )}
      </div>
    </Shell>
  );
}
