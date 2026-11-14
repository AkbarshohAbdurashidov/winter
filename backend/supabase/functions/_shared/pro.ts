// Shared helpers for the Winter edge functions: database client, hashing,
// RevenueCat sync and the `winter_pro` access decision.
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

export const ENTITLEMENT = "winter_pro";

export function env(name: string, fallback = ""): string {
  return Deno.env.get(name) ?? fallback;
}

/// Service-role client: bypasses RLS. Never leaves the server.
export function adminClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

export async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomToken(bytes = 32): string {
  const buf = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...buf)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// Constant-time string comparison for shared secrets.
export function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (s: unknown): s is string => typeof s === "string" && UUID.test(s);

export type Access = "free" | "trial" | "active" | "lifetime" | "expired" | "refunded" | "none";

export interface SubscriptionRow {
  app_user_id: string;
  status: "trial" | "active" | "lifetime" | "expired" | "refunded" | "none";
  product_id?: string | null;
  period_type?: string | null;
  store?: string | null;
  environment?: string | null;
  will_renew?: boolean | null;
  billing_issue?: boolean;
  purchased_at?: string | null;
  expires_at?: string | null;
  had_trial?: boolean;
  converted_from_trial?: boolean;
  revenue_usd?: number;
  management_url?: string | null;
  last_event?: string | null;
  updated_at?: string;
}

/// A status that grants access must still be within its period.
export function effectiveStatus(row: SubscriptionRow | null): SubscriptionRow["status"] {
  if (!row) return "none";
  if ((row.status === "trial" || row.status === "active") && row.expires_at &&
      new Date(row.expires_at).getTime() <= Date.now()) {
    return "expired";
  }
  return row.status;
}

/// Reads the customer from RevenueCat (REST v1, secret key) and stores the
/// `winter_pro` state. Returns null when RevenueCat isn't configured or the
/// request fails (the stored row is then used as is).
export async function refreshFromRevenueCat(
  db: SupabaseClient,
  appUserId: string,
): Promise<SubscriptionRow | null> {
  const key = env("REVENUECAT_SECRET_KEY");
  if (!key) return null;
  let body: any;
  try {
    const res = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`,
      { headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" } },
    );
    if (!res.ok) {
      console.error("RevenueCat", res.status, await res.text());
      return null;
    }
    body = await res.json();
  } catch (e) {
    console.error("RevenueCat fetch failed", e);
    return null;
  }
  const sub = body?.subscriber ?? {};
  const subscriptions: Record<string, any> = sub.subscriptions ?? {};
  const nonSubscriptions: Record<string, any[]> = sub.non_subscriptions ?? {};
  const ent = sub.entitlements?.[ENTITLEMENT];

  const { data: existing } = await db.from("subscriptions").select("*")
    .eq("app_user_id", appUserId).maybeSingle();
  const hadTrial = Boolean(existing?.had_trial) ||
    Object.values(subscriptions).some((s: any) => String(s?.period_type).toLowerCase() === "trial");

  let row: SubscriptionRow;
  if (!ent) {
    row = { app_user_id: appUserId, status: existing ? effectiveStatus(existing) : "none" };
    if (row.status === "trial" || row.status === "active" || row.status === "lifetime") {
      row.status = "expired"; // RevenueCat no longer lists the entitlement
    }
  } else {
    const product: string = ent.product_identifier;
    const s = subscriptions[product];
    const nonSub = nonSubscriptions[product]?.[0];
    const expires: string | null = ent.expires_date ?? null;
    const active = expires === null || new Date(expires).getTime() > Date.now();
    const period = s?.period_type ? String(s.period_type).toUpperCase() : (expires ? "NORMAL" : null);
    let status: SubscriptionRow["status"];
    if (!active) status = s?.refunded_at ? "refunded" : "expired";
    else if (expires === null) status = "lifetime";
    else if (period === "TRIAL") status = "trial";
    else status = "active";
    row = {
      app_user_id: appUserId,
      status,
      product_id: product,
      period_type: period,
      store: s?.store ?? nonSub?.store ?? null,
      environment: (s?.is_sandbox ?? nonSub?.is_sandbox) ? "SANDBOX" : "PRODUCTION",
      will_renew: s ? s.unsubscribe_detected_at == null && s.billing_issues_detected_at == null : null,
      billing_issue: Boolean(s?.billing_issues_detected_at),
      purchased_at: ent.purchase_date ?? null,
      expires_at: expires,
    };
  }
  row.had_trial = hadTrial;
  row.management_url = sub.management_url ?? existing?.management_url ?? null;
  row.updated_at = new Date().toISOString();
  const { error } = await db.from("subscriptions").upsert(row);
  if (error) console.error("store subscription", error);
  return { ...existing, ...row };
}

export interface AccessInfo {
  pro: boolean;
  access: Access;
  productId: string | null;
  expiresAt: string | null;
  willRenew: boolean | null;
  hadTrial: boolean;
  manageUrl: string | null;
  grantNote?: string | null;
}

const STALE_MS = 15 * 60 * 1000;

/// Decides whether a user has `winter_pro`: an admin's free grant first,
/// then the RevenueCat subscription (refreshed when stale or `force`).
export async function accessFor(
  db: SupabaseClient,
  userId: string,
  email: string | null,
  force = false,
): Promise<AccessInfo> {
  if (email) {
    const { data: grant } = await db.rpc("active_grant", { p_email: email });
    const g = Array.isArray(grant) ? grant[0] : grant;
    if (g?.id) {
      return {
        pro: true, access: "free", productId: null, expiresAt: g.expires_at ?? null,
        willRenew: null, hadTrial: false, manageUrl: null, grantNote: g.note ?? null,
      };
    }
  }
  let { data: row } = await db.from("subscriptions").select("*")
    .eq("app_user_id", userId).maybeSingle();
  const stale = !row || Date.now() - new Date(row.updated_at).getTime() > STALE_MS ||
    effectiveStatus(row) !== row.status;
  if (force || stale) row = (await refreshFromRevenueCat(db, userId)) ?? row;
  const status = effectiveStatus(row);
  return {
    pro: status === "trial" || status === "active" || status === "lifetime",
    access: status,
    productId: row?.product_id ?? null,
    expiresAt: row?.expires_at ?? null,
    willRenew: row?.will_renew ?? null,
    hadTrial: Boolean(row?.had_trial),
    manageUrl: row?.management_url ?? null,
  };
}

/// Where "Upgrade" goes: the RevenueCat Web Purchase Link for this user
/// (its paywall shows the current offering), or the portal's upgrade page.
export function upgradeUrl(userId: string | null, email: string | null): string {
  const link = env("REVENUECAT_PURCHASE_LINK").replace(/\/+$/, "");
  if (link && userId) {
    const q = email ? `?email=${encodeURIComponent(email)}` : "";
    return `${link}/${encodeURIComponent(userId)}${q}`;
  }
  return `${env("PORTAL_URL").replace(/\/+$/, "")}/upgrade`;
}
