import { ErrorCode, Purchases, PurchasesError } from "@revenuecat/purchases-js";
import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { SignIn } from "../components/SignIn";
import { Notice, Shell, Snowflake, Spinner } from "../components/ui";
import { callApp, config, type AccountInfo } from "../lib/api";
import { useSession } from "../lib/session";

/// RevenueCat Web Paywall for the signed-in user (app_user_id = Supabase
/// user id). Shows the current offering (Monthly / Yearly / Lifetime) as
/// designed in the RevenueCat dashboard; checkout supports card, Apple Pay
/// and Google Pay. Falls back to the Web Purchase Link without a web key.
export function UpgradePage() {
  const { session, loading } = useSession();
  const target = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<"loading" | "paywall" | "owned" | "success" | "error">("loading");
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    (async () => {
      try {
        const account = await callApp<AccountInfo>("/account", {}, session);
        if (cancelled) return;
        if (account.pro) return setState("owned");

        const userId = session.user.id;
        const email = session.user.email ?? undefined;
        if (!config.revenueCatWebKey) {
          if (config.purchaseLink) {
            const q = email ? `?email=${encodeURIComponent(email)}` : "";
            window.location.href = `${config.purchaseLink}/${encodeURIComponent(userId)}${q}`;
            return;
          }
          throw new Error("Payments are not configured yet.");
        }

        const purchases = Purchases.isConfigured()
          ? Purchases.getSharedInstance()
          : Purchases.configure({ apiKey: config.revenueCatWebKey, appUserId: userId });
        if (purchases.getAppUserId() !== userId) await purchases.changeUser(userId);

        // Already entitled according to RevenueCat (e.g. webhook not yet processed).
        const info = await purchases.getCustomerInfo();
        if ("winter_pro" in info.entitlements.active) {
          await callApp("/account", { refresh: true }, session);
          return setState("owned");
        }

        setState("paywall");
        const offerings = await purchases.getOfferings();
        const result = await purchases.presentPaywall({
          htmlTarget: target.current ?? undefined,
          offering: offerings.current ?? undefined,
          customerEmail: email,
        });
        if (cancelled) return;
        const active = "winter_pro" in result.customerInfo.entitlements.active;
        await callApp("/account", { refresh: true }, session); // sync our backend now
        setState(active ? "success" : "error");
        if (!active) setMessage("The purchase finished but Pro isn't active yet. Refresh your account in a minute.");
      } catch (e) {
        if (cancelled) return;
        if (e instanceof PurchasesError && e.errorCode === ErrorCode.UserCancelledError) {
          setState("error");
          setMessage("Purchase cancelled — nothing was charged.");
          return;
        }
        console.error(e);
        setState("error");
        setMessage(e instanceof Error ? e.message : "Something went wrong.");
      }
    })();
    return () => { cancelled = true; };
  }, [session]);

  if (loading) return <Shell><div className="grid place-items-center py-24"><Spinner /></div></Shell>;
  if (!session) {
    return <Shell><div className="pt-10"><SignIn title="Get Winter Pro" subtitle="Sign in first so Pro is linked to your account." /></div></Shell>;
  }

  return (
    <Shell>
      <div className="mx-auto max-w-3xl pt-4">
        {state === "loading" && <div className="grid place-items-center py-24"><Spinner /></div>}
        {(state === "owned" || state === "success") && (
          <div className="glass p-10 text-center">
            <span className="mx-auto mb-5 grid h-16 w-16 place-items-center rounded-2xl bg-sky-300/15 ring-1 ring-sky-200/30">
              <Snowflake className="h-8 w-8 text-sky-200" />
            </span>
            <h1 className="text-2xl font-semibold text-white">{state === "success" ? "Welcome to Winter Pro!" : "You already have Winter Pro"}</h1>
            <p className="mt-2 text-slate-400">Winter on your computer updates within a minute — or choose “Refresh Pro Status” in its menu.</p>
            <Link to="/account" className="btn-primary mt-6">Go to account</Link>
          </div>
        )}
        {state === "error" && (
          <div className="space-y-4">
            <Notice tone="error">{message}</Notice>
            <div className="flex gap-2">
              <button className="btn-primary" onClick={() => window.location.reload()}>Try again</button>
              <Link to="/account" className="btn-ghost">Back to account</Link>
            </div>
          </div>
        )}
        <div ref={target} className={state === "paywall" ? "glass min-h-[560px] overflow-hidden" : "hidden"} />
      </div>
    </Shell>
  );
}
