// Shared helpers: Firestore access, hashing, RevenueCat sync and the
// `winter_pro` access decision.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore, Timestamp } from "firebase-admin/firestore";

if (!getApps().length) initializeApp();
export const db = getFirestore();
export const auth = getAuth();
export { FieldValue, Timestamp };

export const ENTITLEMENT = "winter_pro";

export const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");
export const randomToken = () => randomBytes(32).toString("base64url");

export function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

const UUIDISH = /^[A-Za-z0-9]{20,128}$/; // Firebase uids
export const isUid = (s: unknown): s is string =>
  typeof s === "string" && UUIDISH.test(s) && !s.startsWith("$RCAnonymousID");

export const iso = (v: unknown): string | null =>
  v instanceof Timestamp ? v.toDate().toISOString() : typeof v === "string" ? v : null;
export const ts = (v: string | number | null | undefined) =>
  v == null ? null : Timestamp.fromDate(new Date(v));

export type Status = "trial" | "active" | "lifetime" | "expired" | "refunded" | "none";
export type Access = Status | "free";

export interface SubscriptionDoc {
  status: Status;
  productId?: string | null;
  periodType?: string | null;
  store?: string | null;
  environment?: string | null;
  willRenew?: boolean | null;
  billingIssue?: boolean;
  purchasedAt?: Timestamp | null;
  expiresAt?: Timestamp | null; // null = lifetime
  hadTrial?: boolean;
  convertedFromTrial?: boolean;
  revenueUsd?: number;
  managementUrl?: string | null;
  lastEvent?: string | null;
  updatedAt?: Timestamp;
}

/// A status that grants access must still be within its period.
export function effectiveStatus(s: SubscriptionDoc | undefined | null): Status {
  if (!s) return "none";
  if ((s.status === "trial" || s.status === "active") && s.expiresAt &&
      s.expiresAt.toMillis() <= Date.now()) return "expired";
  return s.status;
}

/// Reads the customer from RevenueCat (REST v1, secret key) and stores the
/// `winter_pro` state. Returns null when RevenueCat isn't configured or fails.
export async function refreshFromRevenueCat(uid: string, secretKey: string): Promise<SubscriptionDoc | null> {
  if (!secretKey) return null;
  let body: any;
  try {
    const res = await fetch(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(uid)}`,
      { headers: { Authorization: `Bearer ${secretKey}`, "Content-Type": "application/json" } });
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
  const subs: Record<string, any> = sub.subscriptions ?? {};
  const nonSubs: Record<string, any[]> = sub.non_subscriptions ?? {};
  const ent = sub.entitlements?.[ENTITLEMENT];
  const ref = db.collection("subscriptions").doc(uid);
  const existing = (await ref.get()).data() as SubscriptionDoc | undefined;
  const hadTrial = Boolean(existing?.hadTrial) ||
    Object.values(subs).some((s: any) => String(s?.period_type).toLowerCase() === "trial");

  let doc: SubscriptionDoc;
  if (!ent) {
    let status = effectiveStatus(existing);
    if (status === "trial" || status === "active" || status === "lifetime") status = "expired";
    doc = { status };
  } else {
    const product: string = ent.product_identifier;
    const s = subs[product];
    const n = nonSubs[product]?.[0];
    const expires: string | null = ent.expires_date ?? null;
    const active = expires === null || new Date(expires).getTime() > Date.now();
    const period = s?.period_type ? String(s.period_type).toUpperCase() : expires ? "NORMAL" : null;
    const status: Status = !active ? (s?.refunded_at ? "refunded" : "expired")
      : expires === null ? "lifetime" : period === "TRIAL" ? "trial" : "active";
    doc = {
      status,
      productId: product,
      periodType: period,
      store: s?.store ?? n?.store ?? null,
      environment: (s?.is_sandbox ?? n?.is_sandbox) ? "SANDBOX" : "PRODUCTION",
      willRenew: s ? s.unsubscribe_detected_at == null && s.billing_issues_detected_at == null : null,
      billingIssue: Boolean(s?.billing_issues_detected_at),
      purchasedAt: ts(ent.purchase_date),
      expiresAt: ts(expires),
    };
  }
  doc.hadTrial = hadTrial;
  doc.managementUrl = sub.management_url ?? existing?.managementUrl ?? null;
  doc.updatedAt = Timestamp.now();
  await ref.set(doc, { merge: true });
  return { ...existing, ...doc };
}

export interface Grant {
  id: string;
  email: string;
  note?: string | null;
  expiresAt?: Timestamp | null;
  revokedAt?: Timestamp | null;
}

export async function activeGrant(email: string | null | undefined): Promise<Grant | null> {
  if (!email) return null;
  const snap = await db.collection("grants")
    .where("email", "==", email.toLowerCase()).where("revokedAt", "==", null).get();
  const now = Date.now();
  const active = snap.docs.map((d) => ({ id: d.id, ...d.data() } as Grant))
    .filter((g) => !g.expiresAt || g.expiresAt.toMillis() > now)
    .sort((a, b) => (b.expiresAt?.toMillis() ?? Infinity) - (a.expiresAt?.toMillis() ?? Infinity));
  return active[0] ?? null;
}

const STALE_MS = 15 * 60 * 1000;

/// Free grant first, then the RevenueCat subscription (refreshed when stale).
export async function accessFor(uid: string, email: string | null, secretKey: string, force = false) {
  const grant = await activeGrant(email);
  if (grant) {
    return {
      pro: true, access: "free" as Access, productId: null, expiresAt: iso(grant.expiresAt),
      willRenew: null, hadTrial: false, manageUrl: null, grantNote: grant.note ?? null,
    };
  }
  let s = (await db.collection("subscriptions").doc(uid).get()).data() as SubscriptionDoc | undefined;
  const stale = !s || !s.updatedAt || Date.now() - s.updatedAt.toMillis() > STALE_MS || effectiveStatus(s) !== s.status;
  if (force || stale) s = (await refreshFromRevenueCat(uid, secretKey)) ?? s;
  const status = effectiveStatus(s);
  return {
    pro: status === "trial" || status === "active" || status === "lifetime",
    access: status as Access,
    productId: s?.productId ?? null,
    expiresAt: iso(s?.expiresAt),
    willRenew: s?.willRenew ?? null,
    hadTrial: Boolean(s?.hadTrial),
    manageUrl: s?.managementUrl ?? null,
  };
}
