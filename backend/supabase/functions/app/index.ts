// API for the Winter desktop app and the web portal.
//
// Desktop app (no Supabase session; identified by an opaque device token):
//   POST /app/heartbeat     {installId, platform, osVersion, appVersion, launch?, token?}
//   POST /app/link/start    {installId, code, next?}  -> {url}
//   POST /app/link/poll     {installId, code, platform?} -> {status, token?}
//   POST /app/status        {token?}                  -> access summary
//   POST /app/signout       {token}
// Web portal (Authorization: Bearer <Supabase access token>):
//   POST /app/link/approve  {code}
//   POST /app/account       {refresh?}                -> access summary + devices
//   POST /app/devices/revoke {tokenHash}
//   POST /app/admin/refresh {userId}                  (admins only)
import {
  accessFor, adminClient, cors, env, isUuid, json, randomToken, refreshFromRevenueCat,
  sha256, upgradeUrl,
} from "../_shared/pro.ts";

const db = adminClient();
const LINK_TTL_MS = 15 * 60 * 1000;

type Body = Record<string, unknown>;
const str = (v: unknown, max = 200) => (typeof v === "string" ? v.slice(0, max) : undefined);

async function deviceFor(token: unknown) {
  if (typeof token !== "string" || token.length < 20) return null;
  const { data } = await db.from("devices").select("*")
    .eq("token_hash", await sha256(token)).is("revoked_at", null).maybeSingle();
  return data;
}

async function emailOf(userId: string): Promise<string | null> {
  const { data } = await db.auth.admin.getUserById(userId);
  return data?.user?.email ?? null;
}

async function sessionUser(req: Request) {
  const jwt = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!jwt) return null;
  const { data, error } = await db.auth.getUser(jwt);
  return error ? null : data.user;
}

async function isAdmin(email: string | undefined | null) {
  if (!email) return false;
  const { data } = await db.from("admins").select("email").eq("email", email.toLowerCase()).maybeSingle();
  return Boolean(data);
}

function portal(path: string) {
  return `${env("PORTAL_URL", "http://localhost:5173").replace(/\/+$/, "")}${path}`;
}

async function summary(userId: string, email: string | null, force = false) {
  const access = await accessFor(db, userId, email, force);
  return {
    signedIn: true,
    email,
    userId,
    ...access,
    upgradeUrl: upgradeUrl(userId, email),
    accountUrl: portal("/account"),
    checkedAt: new Date().toISOString(),
  };
}

const routes: Record<string, (body: Body, req: Request) => Promise<Response>> = {
  async "/heartbeat"(b) {
    const installId = str(b.installId, 64);
    if (!installId || installId.length < 16) return json({ error: "installId" }, 400);
    const device = await deviceFor(b.token);
    const fields = {
      platform: str(b.platform, 20) ?? "unknown",
      os_version: str(b.osVersion, 120) ?? null,
      app_version: str(b.appVersion, 40) ?? null,
      last_seen: new Date().toISOString(),
      ...(device ? { user_id: device.user_id } : {}),
    };
    const { data: existing } = await db.from("installs").select("launches")
      .eq("install_id", installId).maybeSingle();
    if (existing) {
      await db.from("installs").update({
        ...fields, launches: existing.launches + (b.launch ? 1 : 0),
      }).eq("install_id", installId);
    } else {
      await db.from("installs").insert({ install_id: installId, ...fields });
    }
    if (device) {
      await db.from("devices").update({ last_seen: fields.last_seen }).eq("token_hash", device.token_hash);
    }
    return json({ ok: true });
  },

  async "/link/start"(b) {
    const code = str(b.code, 128);
    if (!code || code.length < 32) return json({ error: "code" }, 400);
    await db.from("device_links").delete().lt("created_at", new Date(Date.now() - LINK_TTL_MS).toISOString());
    const { error } = await db.from("device_links").insert({
      code_hash: await sha256(code), install_id: str(b.installId, 64) ?? null,
    });
    if (error) return json({ error: "link" }, 400);
    const next = b.next === "upgrade" ? "&next=upgrade" : "";
    return json({ url: portal(`/link?code=${encodeURIComponent(code)}${next}`) });
  },

  async "/link/approve"(b, req) {
    const user = await sessionUser(req);
    if (!user) return json({ error: "unauthorized" }, 401);
    const code = str(b.code, 128);
    if (!code) return json({ error: "code" }, 400);
    const { data, error } = await db.from("device_links")
      .update({ user_id: user.id, approved_at: new Date().toISOString() })
      .eq("code_hash", await sha256(code)).is("consumed_at", null).is("approved_at", null)
      .gt("created_at", new Date(Date.now() - LINK_TTL_MS).toISOString())
      .select("code_hash");
    if (error || !data?.length) return json({ error: "expired" }, 410);
    return json({ ok: true });
  },

  async "/link/poll"(b) {
    const code = str(b.code, 128);
    if (!code) return json({ error: "code" }, 400);
    const hash = await sha256(code);
    const { data: link } = await db.from("device_links").select("*").eq("code_hash", hash).maybeSingle();
    if (!link || Date.now() - new Date(link.created_at).getTime() > LINK_TTL_MS || link.consumed_at) {
      return json({ status: "expired" });
    }
    if (!link.approved_at || !link.user_id) return json({ status: "pending" });
    // Consume exactly once, even with concurrent polls.
    const { data: claimed } = await db.from("device_links")
      .update({ consumed_at: new Date().toISOString() })
      .eq("code_hash", hash).is("consumed_at", null).select("code_hash");
    if (!claimed?.length) return json({ status: "expired" });
    const token = randomToken();
    const installId = str(b.installId, 64) ?? link.install_id;
    await db.from("devices").insert({
      token_hash: await sha256(token), user_id: link.user_id,
      install_id: installId, platform: str(b.platform, 20) ?? null,
    });
    if (installId) await db.from("installs").update({ user_id: link.user_id }).eq("install_id", installId);
    return json({ status: "approved", token, email: await emailOf(link.user_id) });
  },

  async "/status"(b) {
    const device = await deviceFor(b.token);
    if (!device) {
      return json({
        signedIn: false, pro: false, access: "none",
        upgradeUrl: portal("/upgrade"), accountUrl: portal("/account"),
        checkedAt: new Date().toISOString(),
      });
    }
    return json(await summary(device.user_id, await emailOf(device.user_id)));
  },

  async "/signout"(b) {
    const device = await deviceFor(b.token);
    if (device) {
      await db.from("devices").update({ revoked_at: new Date().toISOString() })
        .eq("token_hash", device.token_hash);
    }
    return json({ ok: true });
  },

  async "/account"(b, req) {
    const user = await sessionUser(req);
    if (!user) return json({ error: "unauthorized" }, 401);
    const info = await summary(user.id, user.email ?? null, b.refresh === true);
    const { data: devices } = await db.from("devices")
      .select("token_hash, platform, created_at, last_seen")
      .eq("user_id", user.id).is("revoked_at", null).order("last_seen", { ascending: false });
    return json({ ...info, isAdmin: await isAdmin(user.email), devices: devices ?? [] });
  },

  async "/devices/revoke"(b, req) {
    const user = await sessionUser(req);
    if (!user) return json({ error: "unauthorized" }, 401);
    const hash = str(b.tokenHash, 64);
    if (!hash) return json({ error: "tokenHash" }, 400);
    let q = db.from("devices").update({ revoked_at: new Date().toISOString() }).eq("token_hash", hash);
    if (!(await isAdmin(user.email))) q = q.eq("user_id", user.id);
    await q;
    return json({ ok: true });
  },

  async "/admin/refresh"(b, req) {
    const user = await sessionUser(req);
    if (!user || !(await isAdmin(user.email))) return json({ error: "forbidden" }, 403);
    if (!isUuid(b.userId)) return json({ error: "userId" }, 400);
    const row = await refreshFromRevenueCat(db, b.userId);
    return json({ ok: row !== null, row, configured: Boolean(env("REVENUECAT_SECRET_KEY")) });
  },
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const path = new URL(req.url).pathname.replace(/^.*?\/app(?=\/|$)/, "") || "/";
  const handler = routes[path];
  if (!handler) return json({ error: "not found" }, 404);
  let body: Body = {};
  try {
    body = (await req.json()) ?? {};
  } catch {
    // empty body
  }
  try {
    return await handler(body, req);
  } catch (e) {
    console.error(path, e);
    return json({ error: "server" }, 500);
  }
});
