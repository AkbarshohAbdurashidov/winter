// Winter backend on Firebase.
//
// `app` — API for the desktop app and the web portal:
//   Desktop app (no Firebase session; identified by an opaque device token):
//     POST /heartbeat      {installId, platform, osVersion, appVersion, launch?, token?}
//     POST /link/start     {installId, code, next?}   -> {url}
//     POST /link/poll      {installId, code, platform?} -> {status, token?, email?}
//     POST /status         {token?}                   -> access summary
//     POST /signout        {token}
//   Web portal (Authorization: Bearer <Firebase ID token>):
//     POST /link/approve   {code}
//     POST /account        {refresh?}
//     POST /devices/revoke {tokenHash}
//     POST /admin/refresh  {userId}       (admins)
//     POST /admin/users                   (admins) -> rows for the Users table
//     POST /admin/stats                   (admins) -> dashboard numbers
// `revenuecatWebhook` — RevenueCat -> Firestore `subscriptions`.
import type { Request } from "firebase-functions/v2/https";
import { onRequest } from "firebase-functions/v2/https";
import { setGlobalOptions } from "firebase-functions/v2/options";
import { defineSecret, defineString } from "firebase-functions/params";
import type { Response } from "express";
import type { DecodedIdToken } from "firebase-admin/auth";
import {
  accessFor, auth, db, effectiveStatus, ENTITLEMENT, FieldValue, isUid, iso, randomToken,
  refreshFromRevenueCat, safeEqual, sha256, Timestamp, ts, type SubscriptionDoc,
} from "./pro";

setGlobalOptions({ region: "europe-west1", maxInstances: 10 });

const REVENUECAT_SECRET_KEY = defineSecret("REVENUECAT_SECRET_KEY");
const REVENUECAT_WEBHOOK_AUTH = defineSecret("REVENUECAT_WEBHOOK_AUTH");
const PORTAL_URL = defineString("PORTAL_URL", { default: "http://localhost:5173" });
const PURCHASE_LINK = defineString("REVENUECAT_PURCHASE_LINK", { default: "" });

const LINK_TTL_MS = 15 * 60 * 1000;
type Body = Record<string, unknown>;
const str = (v: unknown, max = 200) => (typeof v === "string" ? v.slice(0, max) : undefined);
const portal = (path: string) => `${PORTAL_URL.value().replace(/\/+$/, "")}${path}`;
const rcKey = () => {
  try {
    return REVENUECAT_SECRET_KEY.value() === "unset" ? "" : REVENUECAT_SECRET_KEY.value();
  } catch {
    return "";
  }
};

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

function upgradeUrl(uid: string | null, email: string | null) {
  const link = PURCHASE_LINK.value().replace(/\/+$/, "");
  if (link && uid) return `${link}/${encodeURIComponent(uid)}${email ? `?email=${encodeURIComponent(email)}` : ""}`;
  return portal("/upgrade");
}

async function deviceFor(token: unknown) {
  if (typeof token !== "string" || token.length < 20) return null;
  const ref = db.collection("devices").doc(sha256(token));
  const snap = await ref.get();
  const d = snap.data();
  return d && !d.revokedAt ? { ref, ...d } as { ref: FirebaseFirestore.DocumentReference; userId: string } : null;
}

async function emailOf(uid: string) {
  try {
    return (await auth.getUser(uid)).email ?? null;
  } catch {
    return null;
  }
}

/// Signed-in portal user with a verified email (Google or email link).
async function sessionUser(req: Request): Promise<DecodedIdToken> {
  const jwt = req.headers.authorization?.replace(/^Bearer\s+/i, "");
  if (!jwt) throw new HttpError(401, "unauthorized");
  try {
    const user = await auth.verifyIdToken(jwt);
    if (!user.email || !user.email_verified) throw new Error("unverified");
    return user;
  } catch {
    throw new HttpError(401, "unauthorized");
  }
}

async function isAdmin(email: string | undefined | null) {
  if (!email) return false;
  return (await db.collection("admins").doc(email.toLowerCase()).get()).exists;
}

async function requireAdmin(req: Request) {
  const user = await sessionUser(req);
  if (!(await isAdmin(user.email))) throw new HttpError(403, "forbidden");
  return user;
}

async function summary(uid: string, email: string | null, force = false) {
  return {
    signedIn: true, email, userId: uid,
    ...(await accessFor(uid, email, rcKey(), force)),
    upgradeUrl: upgradeUrl(uid, email),
    accountUrl: portal("/account"),
    checkedAt: new Date().toISOString(),
  };
}

const platformOf = (b: Body) => str(b.platform, 20) ?? "unknown";

const routes: Record<string, (b: Body, req: Request) => Promise<unknown>> = {
  async "/heartbeat"(b) {
    const installId = str(b.installId, 64);
    if (!installId || installId.length < 16 || !/^[A-Za-z0-9_-]+$/.test(installId)) throw new HttpError(400, "installId");
    const device = await deviceFor(b.token);
    const ref = db.collection("installs").doc(installId);
    await db.runTransaction(async (t) => {
      const snap = await t.get(ref);
      const fields: Record<string, unknown> = {
        platform: platformOf(b),
        osVersion: str(b.osVersion, 120) ?? null,
        appVersion: str(b.appVersion, 40) ?? null,
        lastSeen: FieldValue.serverTimestamp(),
        ...(device ? { userId: device.userId } : {}),
      };
      if (snap.exists) {
        t.update(ref, { ...fields, ...(b.launch ? { launches: FieldValue.increment(1) } : {}) });
      } else {
        t.set(ref, { ...fields, userId: device?.userId ?? null, firstSeen: FieldValue.serverTimestamp(), launches: 1 });
      }
    });
    if (device) await device.ref.update({ lastSeen: FieldValue.serverTimestamp() });
    return { ok: true };
  },

  async "/link/start"(b) {
    const code = str(b.code, 128);
    if (!code || code.length < 32) throw new HttpError(400, "code");
    const old = await db.collection("deviceLinks")
      .where("createdAt", "<", Timestamp.fromMillis(Date.now() - LINK_TTL_MS)).limit(100).get();
    await Promise.all(old.docs.map((d) => d.ref.delete()));
    await db.collection("deviceLinks").doc(sha256(code)).create({
      installId: str(b.installId, 64) ?? null, userId: null,
      createdAt: Timestamp.now(), approvedAt: null, consumedAt: null,
    });
    const next = b.next === "upgrade" ? "&next=upgrade" : "";
    return { url: portal(`/link?code=${encodeURIComponent(code)}${next}`) };
  },

  async "/link/approve"(b, req) {
    const user = await sessionUser(req);
    const code = str(b.code, 128);
    if (!code) throw new HttpError(400, "code");
    const ref = db.collection("deviceLinks").doc(sha256(code));
    await db.runTransaction(async (t) => {
      const l = (await t.get(ref)).data();
      if (!l || l.approvedAt || l.consumedAt || Date.now() - l.createdAt.toMillis() > LINK_TTL_MS) {
        throw new HttpError(410, "expired");
      }
      t.update(ref, { userId: user.uid, approvedAt: Timestamp.now() });
    });
    return { ok: true };
  },

  async "/link/poll"(b) {
    const code = str(b.code, 128);
    if (!code) throw new HttpError(400, "code");
    const ref = db.collection("deviceLinks").doc(sha256(code));
    const token = randomToken();
    // Consume exactly once, even with concurrent polls.
    const result = await db.runTransaction(async (t) => {
      const l = (await t.get(ref)).data();
      if (!l || l.consumedAt || Date.now() - l.createdAt.toMillis() > LINK_TTL_MS) return { status: "expired" };
      if (!l.approvedAt || !l.userId) return { status: "pending" };
      const installId = str(b.installId, 64) ?? l.installId ?? null;
      t.update(ref, { consumedAt: Timestamp.now() });
      t.set(db.collection("devices").doc(sha256(token)), {
        userId: l.userId, installId, platform: str(b.platform, 20) ?? null,
        createdAt: Timestamp.now(), lastSeen: Timestamp.now(), revokedAt: null,
      });
      return { status: "approved", userId: l.userId as string, installId };
    });
    if (result.status !== "approved") return { status: result.status };
    if (result.installId) {
      await db.collection("installs").doc(result.installId).set({ userId: result.userId }, { merge: true });
    }
    return { status: "approved", token, email: await emailOf(result.userId!) };
  },

  async "/status"(b) {
    const device = await deviceFor(b.token);
    if (!device) {
      return {
        signedIn: false, pro: false, access: "none",
        upgradeUrl: portal("/upgrade"), accountUrl: portal("/account"), checkedAt: new Date().toISOString(),
      };
    }
    return summary(device.userId, await emailOf(device.userId));
  },

  async "/signout"(b) {
    const device = await deviceFor(b.token);
    if (device) await device.ref.update({ revokedAt: Timestamp.now() });
    return { ok: true };
  },

  async "/account"(b, req) {
    const user = await sessionUser(req);
    const info = await summary(user.uid, user.email ?? null, b.refresh === true);
    const devices = await db.collection("devices").where("userId", "==", user.uid).where("revokedAt", "==", null).get();
    return {
      ...info,
      isAdmin: await isAdmin(user.email),
      devices: devices.docs.map((d) => ({
        token_hash: d.id, platform: d.get("platform") ?? null,
        created_at: iso(d.get("createdAt")), last_seen: iso(d.get("lastSeen")),
      })).sort((a, b) => String(b.last_seen).localeCompare(String(a.last_seen))),
    };
  },

  async "/devices/revoke"(b, req) {
    const user = await sessionUser(req);
    const hash = str(b.tokenHash, 64);
    if (!hash) throw new HttpError(400, "tokenHash");
    const ref = db.collection("devices").doc(hash);
    const d = (await ref.get()).data();
    if (d && (d.userId === user.uid || (await isAdmin(user.email)))) await ref.update({ revokedAt: Timestamp.now() });
    return { ok: true };
  },

  async "/admin/refresh"(b, req) {
    await requireAdmin(req);
    if (!isUid(b.userId)) throw new HttpError(400, "userId");
    const key = rcKey();
    const row = await refreshFromRevenueCat(b.userId, key);
    return { ok: row !== null, configured: Boolean(key) };
  },

  async "/admin/users"(_b, req) {
    await requireAdmin(req);
    return { users: await adminUsers() };
  },

  async "/admin/stats"(_b, req) {
    await requireAdmin(req);
    return adminStats();
  },
};

// ------------------------------------------------------------- admin data

async function listAllUsers() {
  const users = [];
  let page: string | undefined;
  do {
    const r = await auth.listUsers(1000, page);
    users.push(...r.users);
    page = r.pageToken;
  } while (page);
  return users;
}

async function adminUsers() {
  const [users, subs, grants, installs] = await Promise.all([
    listAllUsers(),
    db.collection("subscriptions").get(),
    db.collection("grants").where("revokedAt", "==", null).get(),
    db.collection("installs").get(),
  ]);
  const subOf = new Map(subs.docs.map((d) => [d.id, d.data() as SubscriptionDoc]));
  const now = Date.now();
  const grantOf = new Map<string, FirebaseFirestore.DocumentData & { id: string }>();
  for (const g of grants.docs) {
    const exp = g.get("expiresAt") as Timestamp | null;
    if (exp && exp.toMillis() <= now) continue;
    const prev = grantOf.get(g.get("email"));
    if (!prev || !exp || (prev.expiresAt && prev.expiresAt.toMillis() < exp.toMillis())) {
      grantOf.set(g.get("email"), { id: g.id, ...g.data() });
    }
  }
  const installsOf = new Map<string, { count: number; lastSeen: number; platforms: Set<string> }>();
  for (const i of installs.docs) {
    const uid = i.get("userId");
    if (!uid) continue;
    const e = installsOf.get(uid) ?? { count: 0, lastSeen: 0, platforms: new Set<string>() };
    e.count++;
    e.lastSeen = Math.max(e.lastSeen, (i.get("lastSeen") as Timestamp | null)?.toMillis() ?? 0);
    e.platforms.add(i.get("platform"));
    installsOf.set(uid, e);
  }
  return users.map((u) => {
    const s = subOf.get(u.uid);
    const g = u.email ? grantOf.get(u.email.toLowerCase()) : undefined;
    const ins = installsOf.get(u.uid);
    const status = effectiveStatus(s);
    return {
      user_id: u.uid,
      email: u.email ?? "",
      signed_up_at: new Date(u.metadata.creationTime).toISOString(),
      last_sign_in_at: u.metadata.lastSignInTime ? new Date(u.metadata.lastSignInTime).toISOString() : null,
      subscription_status: s ? status : null,
      product_id: s?.productId ?? null,
      period_type: s?.periodType ?? null,
      store: s?.store ?? null,
      environment: s?.environment ?? null,
      will_renew: s?.willRenew ?? null,
      billing_issue: s?.billingIssue ?? null,
      purchased_at: iso(s?.purchasedAt),
      expires_at: iso(s?.expiresAt),
      had_trial: s?.hadTrial ?? false,
      converted_from_trial: s?.convertedFromTrial ?? false,
      revenue_usd: s?.revenueUsd ?? 0,
      grant_id: g?.id ?? null,
      grant_expires_at: iso(g?.expiresAt),
      grant_note: g?.note ?? null,
      installs: ins?.count ?? 0,
      last_seen: ins?.lastSeen ? new Date(ins.lastSeen).toISOString() : null,
      platforms: ins ? [...ins.platforms].sort().join(", ") : null,
      access: g ? "free" : status,
    };
  }).sort((a, b) => b.signed_up_at.localeCompare(a.signed_up_at));
}

async function adminStats() {
  const [installs, subs, grants, users] = await Promise.all([
    db.collection("installs").get(),
    db.collection("subscriptions").get(),
    db.collection("grants").where("revokedAt", "==", null).get(),
    listAllUsers(),
  ]);
  const now = Date.now(), day = 86400000;
  const seen = (d: FirebaseFirestore.QueryDocumentSnapshot, f: string) => (d.get(f) as Timestamp | null)?.toMillis() ?? 0;
  const count = (ms: number) => installs.docs.filter((d) => seen(d, "lastSeen") > now - ms).length;
  const statuses = subs.docs.map((d) => effectiveStatus(d.data() as SubscriptionDoc));
  const platforms: Record<string, number> = {};
  const versions: Record<string, number> = {};
  for (const d of installs.docs) {
    platforms[d.get("platform") ?? "unknown"] = (platforms[d.get("platform") ?? "unknown"] ?? 0) + 1;
    versions[d.get("appVersion") ?? "?"] = (versions[d.get("appVersion") ?? "?"] ?? 0) + 1;
  }
  const today = new Date(); today.setUTCHours(0, 0, 0, 0);
  const days = Array.from({ length: 14 }, (_, i) => {
    const start = today.getTime() - (13 - i) * day;
    return {
      day: new Date(start).toISOString().slice(0, 10),
      count: installs.docs.filter((d) => { const t = seen(d, "firstSeen"); return t >= start && t < start + day; }).length,
    };
  });
  const freeEmails = new Set(grants.docs
    .filter((g) => !g.get("expiresAt") || (g.get("expiresAt") as Timestamp).toMillis() > now).map((g) => g.get("email")));
  return {
    installs: installs.size,
    active_1d: count(day), active_7d: count(7 * day), active_30d: count(30 * day),
    users: users.length,
    trial: statuses.filter((s) => s === "trial").length,
    active: statuses.filter((s) => s === "active").length,
    lifetime: statuses.filter((s) => s === "lifetime").length,
    expired: statuses.filter((s) => s === "expired" || s === "refunded").length,
    free: freeEmails.size,
    trial_conversions: subs.docs.filter((d) => d.get("convertedFromTrial")).length,
    revenue_usd: Math.round(subs.docs.reduce((a, d) => a + (d.get("revenueUsd") ?? 0), 0) * 100) / 100,
    platforms, versions, new_installs_14d: days,
  };
}

// ------------------------------------------------------------- HTTP glue

function cors(res: Response) {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Headers", "authorization, content-type, apikey");
  res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
}

export const app = onRequest({ secrets: [REVENUECAT_SECRET_KEY], cors: false }, async (req, res) => {
  cors(res);
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (req.method !== "POST") { res.status(405).json({ error: "method" }); return; }
  const handler = routes[req.path.replace(/\/+$/, "") || "/"];
  if (!handler) { res.status(404).json({ error: "not found" }); return; }
  try {
    res.json(await handler((req.body && typeof req.body === "object" ? req.body : {}) as Body, req));
  } catch (e) {
    if (e instanceof HttpError) { res.status(e.status).json({ error: e.message }); return; }
    console.error(req.path, e);
    res.status(500).json({ error: "server" });
  }
});

// ------------------------------------------------------------- webhook

const GRANTING = new Set(["INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE",
  "SUBSCRIPTION_EXTENDED", "NON_RENEWING_PURCHASE"]);
const PAID = new Set(["INITIAL_PURCHASE", "RENEWAL", "NON_RENEWING_PURCHASE", "CANCELLATION"]);

/// RevenueCat -> Integrations -> Webhooks. URL = this function's URL,
/// Authorization header = the REVENUECAT_WEBHOOK_AUTH secret.
export const revenuecatWebhook = onRequest(
  { secrets: [REVENUECAT_SECRET_KEY, REVENUECAT_WEBHOOK_AUTH] },
  async (req, res) => {
    if (req.method !== "POST") { res.status(405).json({ error: "method" }); return; }
    const secret = REVENUECAT_WEBHOOK_AUTH.value();
    const header = req.headers.authorization ?? "";
    if (!secret || !(safeEqual(header, secret) || safeEqual(header, `Bearer ${secret}`))) {
      res.status(401).json({ error: "unauthorized" }); return;
    }
    const e = req.body?.event;
    if (!e?.id || !e?.type) { res.status(400).json({ error: "event" }); return; }
    const uid: string | undefined = [e.app_user_id, e.original_app_user_id, ...(e.aliases ?? [])].find(isUid);

    try {
      await db.collection("revenuecatEvents").doc(String(e.id)).create({
        type: e.type, appUserId: uid ?? e.app_user_id ?? null, payload: req.body, receivedAt: Timestamp.now(),
      });
    } catch (err: any) {
      if (err?.code === 6) { res.json({ ok: true, duplicate: true }); return; } // ALREADY_EXISTS: retried delivery
      console.error("store event", err);
      res.status(500).json({ error: "store" }); return; // RevenueCat retries
    }
    const ents: string[] | null = e.entitlement_ids ?? (e.entitlement_id ? [e.entitlement_id] : null);
    if (e.type === "TEST" || !uid || (ents && !ents.includes(ENTITLEMENT))) {
      res.json({ ok: true, ignored: true }); return;
    }

    const ref = db.collection("subscriptions").doc(uid);
    await db.runTransaction(async (t) => {
      const cur = ((await t.get(ref)).data() ?? { status: "none" }) as SubscriptionDoc;
      const d: SubscriptionDoc = { revenueUsd: 0, hadTrial: false, convertedFromTrial: false, billingIssue: false, ...cur };
      const period = typeof e.period_type === "string" ? e.period_type.toUpperCase() : null;
      if (GRANTING.has(e.type)) {
        const expires = ts(e.expiration_at_ms);
        d.status = expires === null ? "lifetime" : period === "TRIAL" ? "trial" : "active";
        d.productId = e.new_product_id ?? e.product_id ?? d.productId ?? null;
        d.periodType = period;
        d.purchasedAt = ts(e.purchased_at_ms) ?? d.purchasedAt ?? null;
        d.expiresAt = expires;
        d.willRenew = expires !== null;
        d.billingIssue = false;
      } else if (e.type === "CANCELLATION") {
        d.willRenew = false;
        if (e.cancel_reason === "CUSTOMER_SUPPORT") d.status = "refunded";
      } else if (e.type === "EXPIRATION") {
        d.status = "expired";
        d.willRenew = false;
      } else if (e.type === "BILLING_ISSUE") {
        d.billingIssue = true;
      }
      if (e.store) d.store = e.store;
      if (e.environment) d.environment = e.environment;
      if (period === "TRIAL") d.hadTrial = true;
      if (e.is_trial_conversion === true) d.convertedFromTrial = true;
      if (PAID.has(e.type) && typeof e.price === "number" && e.price !== 0) {
        d.revenueUsd = Math.round(((d.revenueUsd ?? 0) + e.price) * 100) / 100;
      }
      d.lastEvent = e.type;
      d.updatedAt = Timestamp.now();
      t.set(ref, d);
    });
    // The RevenueCat API is the source of truth for the current state.
    await refreshFromRevenueCat(uid, rcKey());
    res.json({ ok: true });
  },
);

