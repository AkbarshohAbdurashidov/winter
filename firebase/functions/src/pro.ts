// Shared helpers: Firestore access, hashing and the Pro access decision.
//
// Pro = an active document in `grants` for the user's email. Grants are
// created when an admin approves a Pro request (admin panel or Telegram),
// or given directly in the admin panel.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore, Timestamp } from "firebase-admin/firestore";

if (!getApps().length) initializeApp();
export const db = getFirestore();
export const auth = getAuth();
export { FieldValue, Timestamp };

export const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");
export const randomToken = () => randomBytes(32).toString("base64url");

export function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export const iso = (v: unknown): string | null =>
  v instanceof Timestamp ? v.toDate().toISOString() : typeof v === "string" ? v : null;

export interface Grant {
  id: string;
  email: string;
  note?: string | null;
  expiresAt?: Timestamp | null;
  revokedAt?: Timestamp | null;
  requestId?: string | null;
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

export async function accessFor(email: string | null) {
  const grant = await activeGrant(email);
  return grant
    ? { pro: true, access: "pro" as const, expiresAt: iso(grant.expiresAt), grantNote: grant.note ?? null }
    : { pro: false, access: "none" as const, expiresAt: null, grantNote: null };
}

/// Latest Pro request of an email (any status).
export async function latestRequest(email: string | null | undefined) {
  if (!email) return null;
  const snap = await db.collection("proRequests").where("email", "==", email.toLowerCase()).get();
  const docs = snap.docs.sort((a, b) =>
    (b.get("createdAt") as Timestamp).toMillis() - (a.get("createdAt") as Timestamp).toMillis());
  return docs[0] ?? null;
}
