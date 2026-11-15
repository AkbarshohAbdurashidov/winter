// Telegram bot: notifications to the admin chat and the inline buttons that
// approve / reject Pro requests. Every decision (bot or admin panel) goes
// through `decideRequest`, which updates Firestore and then re-renders the
// request's bot message, so both sides always show the same status.
import { defineSecret, defineString } from "firebase-functions/params";
import { db, FieldValue, Timestamp } from "./pro";

export const TELEGRAM_BOT_TOKEN = defineSecret("TELEGRAM_BOT_TOKEN");
export const TELEGRAM_WEBHOOK_SECRET = defineSecret("TELEGRAM_WEBHOOK_SECRET");
export const TELEGRAM_CHAT_ID = defineString("TELEGRAM_CHAT_ID", { default: "" });
export const TELEGRAM_API = defineString("TELEGRAM_API", { default: "https://api.telegram.org" });
/// One bot can serve several apps. Each app tags its messages with APP_NAME and
/// its buttons with APP_ID (`<appId>:<requestId>:<action>`). Telegram sends
/// every button press to the single registered webhook (this one); presses for
/// another app are forwarded to that app's webhook listed in TELEGRAM_ROUTES
/// (`appId=https://…/telegramWebhook,other=https://…`), with the same secret.
export const APP_ID = defineString("APP_ID", { default: "winter" });
export const APP_NAME = defineString("APP_NAME", { default: "Winter" });
export const TELEGRAM_ROUTES = defineString("TELEGRAM_ROUTES", { default: "" });

export function telegramRoute(app: string): string | null {
  for (const part of TELEGRAM_ROUTES.value().split(",")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === app) return part.slice(i + 1).trim() || null;
  }
  return null;
}

const secret = (p: { value(): string }) => {
  try {
    const v = p.value();
    return v === "unset" ? "" : v;
  } catch {
    return "";
  }
};
export const botConfigured = () => Boolean(secret(TELEGRAM_BOT_TOKEN) && TELEGRAM_CHAT_ID.value());
export const webhookSecret = () => secret(TELEGRAM_WEBHOOK_SECRET);

/// Calls the Bot API; null when the bot isn't configured or the call fails.
export async function tg(method: string, body: Record<string, unknown>): Promise<any> {
  const token = secret(TELEGRAM_BOT_TOKEN);
  if (!token) return null;
  try {
    const res = await fetch(`${TELEGRAM_API.value()}/bot${token}/${method}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const j: any = await res.json().catch(() => null);
    if (!j?.ok) console.error("telegram", method, j);
    return j?.ok ? j.result : null;
  } catch (e) {
    console.error("telegram", method, e);
    return null;
  }
}

const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const when = (t: unknown) =>
  t instanceof Timestamp
    ? t.toDate().toLocaleString("en-GB", { timeZone: "Asia/Tashkent", dateStyle: "medium", timeStyle: "short" })
    : "";

export type RequestStatus = "pending" | "approved" | "rejected" | "revoked";
export type Decision = "approve" | "reject" | "revoke";

const STATUS_LINE: Record<RequestStatus, string> = {
  pending: "⏳ <b>Kutilmoqda</b>",
  approved: "✅ <b>Tasdiqlandi</b>",
  rejected: "❌ <b>Rad etildi</b>",
  revoked: "🚫 <b>Pro bekor qilindi</b>",
};

function requestText(id: string, r: FirebaseFirestore.DocumentData) {
  const tgUser = r.telegram ? `@${esc(String(r.telegram).replace(/^@/, ""))}` : "—";
  const lines = [
    `❄️ <b>${esc(APP_NAME.value())} uchun Pro so'rov</b>`,
    `#${esc(APP_ID.value())}`,
    "",
    `👤 <b>Ism:</b> ${esc(r.name)}`,
    `📧 <b>Email:</b> ${esc(r.email)}`,
    `✈️ <b>Telegram:</b> ${tgUser}`,
    `📞 <b>Telefon:</b> ${r.phone ? esc(r.phone) : "—"}`,
    `🕒 ${esc(when(r.createdAt))}`,
    "",
    `Holat: ${STATUS_LINE[r.status as RequestStatus]}`,
  ];
  if (r.status !== "pending" && r.decidedBy) {
    lines.push(`<i>${esc(r.decidedBy)} · ${esc(when(r.decidedAt))}</i>`);
  }
  lines.push(`<code>${esc(id)}</code>`);
  return lines.join("\n");
}

function requestButtons(id: string, status: RequestStatus) {
  const b = (text: string, action: Decision) => ({ text, callback_data: `${APP_ID.value()}:${id}:${action}` });
  const row = status === "pending" ? [b("✅ Tasdiqlash", "approve"), b("❌ Rad etish", "reject")]
    : status === "approved" ? [b("🚫 Pro'ni bekor qilish", "revoke")]
      : [b("✅ Tasdiqlash", "approve")];
  return { inline_keyboard: [row] };
}

/// Sends a new request to the admin chat; stores the message id for edits.
export async function announceRequest(id: string) {
  if (!botConfigured()) return;
  const ref = db.collection("proRequests").doc(id);
  const r = (await ref.get()).data();
  if (!r) return;
  const msg = await tg("sendMessage", {
    chat_id: TELEGRAM_CHAT_ID.value(),
    text: requestText(id, r),
    parse_mode: "HTML",
    reply_markup: requestButtons(id, r.status),
  });
  if (msg?.message_id) await ref.update({ telegramMessageId: msg.message_id, telegramChatId: String(msg.chat.id) });
}

/// Re-renders the request's bot message after a status change.
export async function refreshRequestMessage(id: string) {
  const r = (await db.collection("proRequests").doc(id).get()).data();
  if (!r?.telegramMessageId) return;
  await tg("editMessageText", {
    chat_id: r.telegramChatId ?? TELEGRAM_CHAT_ID.value(),
    message_id: r.telegramMessageId,
    text: requestText(id, r),
    parse_mode: "HTML",
    reply_markup: requestButtons(id, r.status),
  });
}

const NEXT: Record<Decision, { from: RequestStatus[]; to: RequestStatus }> = {
  approve: { from: ["pending", "rejected", "revoked"], to: "approved" },
  reject: { from: ["pending"], to: "rejected" },
  revoke: { from: ["approved"], to: "revoked" },
};

/// The single place where a request changes status. Approving gives the
/// request's email Pro (a grant); revoking ends that grant. A decision that
/// doesn't apply to the current status (e.g. both sides pressed at once) is
/// a no-op that returns the current status.
export async function decideRequest(id: string, decision: Decision, actor: string) {
  const ref = db.collection("proRequests").doc(id);
  const result = await db.runTransaction(async (t) => {
    const snap = await t.get(ref);
    if (!snap.exists) throw new Error("not-found");
    const r = snap.data()!;
    const rule = NEXT[decision];
    if (!rule.from.includes(r.status)) return { status: r.status as RequestStatus, changed: false };
    const now = Timestamp.now();
    const update: Record<string, unknown> = { status: rule.to, decidedBy: actor, decidedAt: now };
    if (decision === "approve") {
      // One active grant per email.
      const active = await t.get(db.collection("grants").where("email", "==", r.email).where("revokedAt", "==", null));
      active.docs.forEach((g) => t.update(g.ref, { revokedAt: now }));
      const grant = db.collection("grants").doc();
      t.set(grant, {
        email: r.email, note: `Pro request (${r.name})`, expiresAt: null,
        createdBy: actor, createdAt: now, revokedAt: null, requestId: id,
      });
      update.grantId = grant.id;
    } else if (decision === "revoke" && r.grantId) {
      t.update(db.collection("grants").doc(r.grantId), { revokedAt: now, revokedBySync: true });
    }
    t.update(ref, update);
    return { status: rule.to, changed: true };
  });
  if (result.changed) await refreshRequestMessage(id);
  return result;
}

/// A grant that came from a request was removed elsewhere (Free access tab,
/// user drawer): mark the request revoked and update the bot message.
export async function syncRevokedGrant(grant: FirebaseFirestore.DocumentData) {
  if (!grant.requestId || grant.revokedBySync) return;
  const ref = db.collection("proRequests").doc(grant.requestId);
  const changed = await db.runTransaction(async (t) => {
    const r = (await t.get(ref)).data();
    if (!r || r.status !== "approved") return false;
    t.update(ref, { status: "revoked", decidedBy: grant.revokedBy ?? "admin panel", decidedAt: FieldValue.serverTimestamp() });
    return true;
  });
  if (changed) await refreshRequestMessage(grant.requestId);
}

export async function announceNewUser(email: string, name: string | null) {
  if (!botConfigured()) return;
  await tg("sendMessage", {
    chat_id: TELEGRAM_CHAT_ID.value(),
    text: `👋 <b>${esc(APP_NAME.value())}</b> · Yangi foydalanuvchi\n#${esc(APP_ID.value())}\n${name ? `${esc(name)}\n` : ""}📧 ${esc(email)}`,
    parse_mode: "HTML",
  });
}
