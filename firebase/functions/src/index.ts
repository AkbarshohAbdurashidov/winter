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
//     POST /hello                          registers the user (+ Telegram notice once)
//     POST /link/approve   {code}
//     POST /account
//     POST /pro/request    {name, telegram?, phone?}
//     POST /devices/revoke {tokenHash}
//     POST /admin/requests/decide {id, action: approve|reject|revoke}  (admins)
//     POST /admin/telegram/status | /admin/telegram/connect          (admins)
//     POST /admin/users | /admin/stats                                (admins)
// `telegramWebhook` — inline buttons of the admin bot.
// `onGrantUpdated` — a request's grant revoked in the panel -> request + bot message.
import type { Request } from "firebase-functions/v2/https";
import { onRequest } from "firebase-functions/v2/https";
import { setGlobalOptions } from "firebase-functions/v2/options";
import { defineString } from "firebase-functions/params";
import type { Response } from "express";
import type { DecodedIdToken } from "firebase-admin/auth";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import {
  accessFor, auth, db, FieldValue, iso, latestRequest, randomToken, safeEqual, sha256, Timestamp,
} from "./pro";
import {
  announceNewUser, announceRequest, botConfigured, decideRequest, syncRevokedGrant, tg,
  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_WEBHOOK_SECRET, webhookSecret, type Decision,
} from "./telegram";

setGlobalOptions({ region: "europe-west1", maxInstances: 10 });

const PORTAL_URL = defineString("PORTAL_URL", { default: "http://localhost:5173" });
/// Comma-separated emails that become admins on their first sign-in, so the
/// first admin doesn't have to be created by hand in the console.
const ADMIN_EMAILS = defineString("ADMIN_EMAILS", { default: "" });

const LINK_TTL_MS = 15 * 60 * 1000;
type Body = Record<string, unknown>;
const str = (v: unknown, max = 200) => (typeof v === "string" ? v.slice(0, max) : undefined);
const portal = (path: string) => `${PORTAL_URL.value().replace(/\/+$/, "")}${path}`;

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
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

async function summary(uid: string, email: string | null) {
  return {
    signedIn: true, email, userId: uid,
    ...(await accessFor(email)),
    upgradeUrl: portal("/upgrade"),
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

  async "/account"(_b, req) {
    const user = await sessionUser(req);
    const info = await summary(user.uid, user.email ?? null);
    const r = await latestRequest(user.email);
    const devices = await db.collection("devices").where("userId", "==", user.uid).where("revokedAt", "==", null).get();
    return {
      ...info,
      isAdmin: await isAdmin(user.email),
      request: r ? requestRow(r) : null,
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

  async "/hello"(_b, req) {
    const user = await sessionUser(req);
    const ref = db.collection("users").doc(user.uid);
    const created = await db.runTransaction(async (t) => {
      if ((await t.get(ref)).exists) return false;
      t.set(ref, { email: user.email!.toLowerCase(), name: user.name ?? null, createdAt: Timestamp.now() });
      return true;
    });
    if (created) await announceNewUser(user.email!, user.name ?? null);
    const email = user.email!.toLowerCase();
    const bootstrap = ADMIN_EMAILS.value().split(",").map((e) => e.trim().toLowerCase()).filter(Boolean);
    if (bootstrap.includes(email)) {
      const admin = db.collection("admins").doc(email);
      if (!(await admin.get()).exists) await admin.set({ addedAt: Timestamp.now(), addedBy: "ADMIN_EMAILS" });
    }
    return { ok: true, created };
  },

  async "/pro/request"(b, req) {
    const user = await sessionUser(req);
    const email = user.email!.toLowerCase();
    const name = str(b.name, 200)?.trim() ?? "";
    if (name.length < 2 || name.length > 80) throw new HttpError(400, "name");
    const telegram = str(b.telegram, 60)?.trim() ?? "";
    if (telegram && !/^@?[A-Za-z0-9_]{4,32}$/.test(telegram)) throw new HttpError(400, "telegram");
    const phone = str(b.phone, 40)?.trim() ?? "";
    if (phone && !/^\+?[0-9 ()-]{7,20}$/.test(phone)) throw new HttpError(400, "phone");
    if ((await accessFor(email)).pro) throw new HttpError(409, "already-pro");
    const prev = await latestRequest(email);
    if (prev?.get("status") === "pending") throw new HttpError(409, "pending");
    const ref = await db.collection("proRequests").add({
      userId: user.uid, email, name,
      telegram: telegram ? telegram.replace(/^@/, "") : null,
      phone: phone || null,
      status: "pending", createdAt: Timestamp.now(), decidedAt: null, decidedBy: null, grantId: null,
    });
    await announceRequest(ref.id);
    return { ok: true, request: requestRow(await ref.get()) };
  },

  async "/admin/requests/decide"(b, req) {
    const admin = await requireAdmin(req);
    const id = str(b.id, 64);
    const action = str(b.action, 10) as Decision | undefined;
    if (!id) throw new HttpError(400, "id");
    if (action !== "approve" && action !== "reject" && action !== "revoke") throw new HttpError(400, "action");
    try {
      return await decideRequest(id, action, admin.email!.toLowerCase());
    } catch (e) {
      if (e instanceof Error && e.message === "not-found") throw new HttpError(404, "not-found");
      throw e;
    }
  },

  async "/admin/telegram/status"(_b, req) {
    await requireAdmin(req);
    const [me, hook] = await Promise.all([tg("getMe", {}), tg("getWebhookInfo", {})]);
    return {
      configured: botConfigured(),
      chatId: TELEGRAM_CHAT_ID.value() || null,
      bot: me ? { username: me.username, name: me.first_name } : null,
      webhookUrl: hook?.url || null,
      expectedUrl: telegramHookUrl(),
      pending: hook?.pending_update_count ?? 0,
      lastError: hook?.last_error_message ?? null,
    };
  },

  async "/admin/telegram/connect"(_b, req) {
    await requireAdmin(req);
    const secret = webhookSecret();
    if (!botConfigured() || !secret) throw new HttpError(412, "bot-not-configured");
    const ok = await tg("setWebhook", {
      url: telegramHookUrl(), secret_token: secret,
      allowed_updates: ["callback_query", "message"], drop_pending_updates: false,
    });
    if (!ok) throw new HttpError(502, "telegram");
    await tg("setMyCommands", { commands: [{ command: "id", description: "Chat ID" }] });
    return { ok: true };
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

function requestRow(d: FirebaseFirestore.DocumentSnapshot) {
  return {
    id: d.id,
    status: d.get("status") as string,
    name: d.get("name") as string,
    email: d.get("email") as string,
    telegram: (d.get("telegram") as string | null) ?? null,
    phone: (d.get("phone") as string | null) ?? null,
    created_at: iso(d.get("createdAt")),
    decided_at: iso(d.get("decidedAt")),
    decided_by: (d.get("decidedBy") as string | null) ?? null,
  };
}

/// Where Telegram posts button presses (Cloud Functions v2 keeps this URL).
function telegramHookUrl() {
  const project = process.env.GCLOUD_PROJECT ?? JSON.parse(process.env.FIREBASE_CONFIG ?? "{}").projectId;
  return `https://europe-west1-${project}.cloudfunctions.net/telegramWebhook`;
}

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
  const [users, grants, installs, requests] = await Promise.all([
    listAllUsers(),
    db.collection("grants").where("revokedAt", "==", null).get(),
    db.collection("installs").get(),
    db.collection("proRequests").get(),
  ]);
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
  const requestOf = new Map<string, FirebaseFirestore.QueryDocumentSnapshot>();
  for (const r of requests.docs) {
    const prev = requestOf.get(r.get("email"));
    if (!prev || (prev.get("createdAt") as Timestamp).toMillis() < (r.get("createdAt") as Timestamp).toMillis()) {
      requestOf.set(r.get("email"), r);
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
    const email = (u.email ?? "").toLowerCase();
    const g = email ? grantOf.get(email) : undefined;
    const r = email ? requestOf.get(email) : undefined;
    const ins = installsOf.get(u.uid);
    return {
      user_id: u.uid,
      email: u.email ?? "",
      name: (r?.get("name") as string | undefined) ?? u.displayName ?? null,
      telegram: (r?.get("telegram") as string | null | undefined) ?? null,
      phone: (r?.get("phone") as string | null | undefined) ?? null,
      request_id: r?.id ?? null,
      request_status: (r?.get("status") as string | undefined) ?? null,
      signed_up_at: new Date(u.metadata.creationTime).toISOString(),
      last_sign_in_at: u.metadata.lastSignInTime ? new Date(u.metadata.lastSignInTime).toISOString() : null,
      grant_id: g?.id ?? null,
      grant_expires_at: iso(g?.expiresAt),
      grant_note: g?.note ?? null,
      installs: ins?.count ?? 0,
      last_seen: ins?.lastSeen ? new Date(ins.lastSeen).toISOString() : null,
      platforms: ins ? [...ins.platforms].sort().join(", ") : null,
      access: g ? "pro" : "none",
    };
  }).sort((a, b) => b.signed_up_at.localeCompare(a.signed_up_at));
}

async function adminStats() {
  const [installs, grants, users, requests] = await Promise.all([
    db.collection("installs").get(),
    db.collection("grants").where("revokedAt", "==", null).get(),
    listAllUsers(),
    db.collection("proRequests").get(),
  ]);
  const now = Date.now(), day = 86400000;
  const seen = (d: FirebaseFirestore.QueryDocumentSnapshot, f: string) => (d.get(f) as Timestamp | null)?.toMillis() ?? 0;
  const count = (ms: number) => installs.docs.filter((d) => seen(d, "lastSeen") > now - ms).length;
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
  const proEmails = new Set(grants.docs
    .filter((g) => !g.get("expiresAt") || (g.get("expiresAt") as Timestamp).toMillis() > now).map((g) => g.get("email")));
  const byStatus = (s: string) => requests.docs.filter((r) => r.get("status") === s).length;
  return {
    installs: installs.size,
    active_1d: count(day), active_7d: count(7 * day), active_30d: count(30 * day),
    users: users.length,
    pro: proEmails.size,
    requests: requests.size,
    pending: byStatus("pending"), approved: byStatus("approved"),
    rejected: byStatus("rejected"), revoked: byStatus("revoked"),
    platforms, versions, new_installs_14d: days,
  };
}

// ------------------------------------------------------------- HTTP glue

function cors(res: Response) {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Headers", "authorization, content-type, apikey");
  res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
}

export const app = onRequest({ secrets: [TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET], cors: false }, async (req, res) => {
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

// ------------------------------------------------------------- Telegram

/// Bot webhook (set from the admin panel: Telegram -> Connect). Telegram
/// sends the secret in X-Telegram-Bot-Api-Secret-Token. Always answers 200
/// so Telegram doesn't retry a bad update forever.
export const telegramWebhook = onRequest(
  { secrets: [TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET] },
  async (req, res) => {
    const secret = webhookSecret();
    const header = String(req.headers["x-telegram-bot-api-secret-token"] ?? "");
    if (!secret || !safeEqual(header, secret)) { res.status(401).json({ error: "unauthorized" }); return; }
    const u = req.body ?? {};
    try {
      if (u.message?.text && /^\/(start|id)\b/.test(u.message.text)) {
        await tg("sendMessage", {
          chat_id: u.message.chat.id,
          text: `Chat ID: <code>${u.message.chat.id}</code>`,
          parse_mode: "HTML",
        });
      }
      const q = u.callback_query;
      if (q) {
        const chat = String(q.message?.chat?.id ?? "");
        const m = /^req:([A-Za-z0-9]{1,64}):(approve|reject|revoke)$/.exec(q.data ?? "");
        if (!m || chat !== TELEGRAM_CHAT_ID.value()) {
          await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Ruxsat yo'q" });
        } else {
          const actor = q.from?.username ? `telegram:@${q.from.username}` : `telegram:${q.from?.id ?? "?"}`;
          let text: string;
          try {
            const r = await decideRequest(m[1], m[2] as Decision, actor);
            text = !r.changed ? "Holat allaqachon o'zgargan"
              : r.status === "approved" ? "✅ Pro berildi"
                : r.status === "rejected" ? "❌ Rad etildi" : "🚫 Pro bekor qilindi";
          } catch {
            text = "So'rov topilmadi";
          }
          await tg("answerCallbackQuery", { callback_query_id: q.id, text });
        }
      }
    } catch (e) {
      console.error("telegramWebhook", e);
    }
    res.json({ ok: true });
  },
);

/// A grant that came from a request was revoked in the admin panel (Free
/// access tab / user drawer): mark the request revoked, update the bot.
export const onGrantUpdated = onDocumentUpdated(
  { document: "grants/{id}", secrets: [TELEGRAM_BOT_TOKEN] },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after || before.revokedAt || !after.revokedAt) return;
    await syncRevokedGrant(after);
  },
);

// ------------------------------------------------------------- downloads

const RELEASES = defineString("RELEASES_URL", {
  default: "https://github.com/AkbarshohAbdurashidov/winter/releases/latest/download",
});
const DOWNLOADS: Record<string, { file: string; type: string }> = {
  mac: { file: "Winter-macOS.dmg", type: "application/x-apple-diskimage" },
  windows: { file: "Winter-Windows-Setup.exe", type: "application/vnd.microsoft.portable-executable" },
  "windows-zip": { file: "Winter-Windows-portable.zip", type: "application/zip" },
};

/// /download/mac | /download/windows | /download/windows-zip on the website
/// (Hosting rewrite). Streams the latest release's file, so the browser
/// downloads from our domain and never opens GitHub. Hosting's CDN caches it
/// for an hour, so most downloads don't reach this function at all.
export const download = onRequest({ memory: "256MiB", timeoutSeconds: 120 }, async (req, res) => {
  const d = DOWNLOADS[req.path.replace(/^\/(download\/)?/, "").replace(/\/+$/, "")];
  if (!d) { res.status(404).send("Not found"); return; }
  const upstream = await fetch(`${RELEASES.value()}/${d.file}`, { redirect: "follow" });
  if (!upstream.ok || !upstream.body) { res.status(502).send("Download unavailable, try again later."); return; }
  res.set("Content-Type", d.type);
  res.set("Content-Disposition", `attachment; filename="${d.file}"`);
  res.set("Cache-Control", "public, max-age=600, s-maxage=3600");
  const len = upstream.headers.get("content-length");
  if (len) res.set("Content-Length", len);
  if (req.method === "HEAD") { res.end(); return; }
  const { Readable } = await import("node:stream");
  Readable.fromWeb(upstream.body as any).pipe(res);
});
