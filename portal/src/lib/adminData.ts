// Admin panel data access. Reads/writes go straight to Firestore (allowed
// for admins by firebase/firestore.rules); joins that need Firebase Auth
// (the user list, stats) come from the `app` Cloud Function.
import {
  addDoc, collection, deleteDoc, doc, getDoc, getDocs, limit, onSnapshot, orderBy, query, serverTimestamp, setDoc,
  Timestamp, updateDoc, where,
} from "firebase/firestore";
import { auth, callApp, db, toIso, type ProRequest, type RequestStatus } from "./api";

const me = () => (auth.currentUser?.email ?? "").toLowerCase();

export async function isAdmin(): Promise<boolean> {
  if (!me()) return false;
  try {
    return (await getDoc(doc(db, "admins", me()))).exists();
  } catch {
    return false;
  }
}

export const fetchStats = <T>() => callApp<T>("/admin/stats");
export const fetchUsers = async <T>() => (await callApp<{ users: T[] }>("/admin/users")).users;

/// Live list of Pro requests: changes made in Telegram show up immediately.
export function watchRequests(onChange: (rows: ProRequest[]) => void, onError: (e: Error) => void) {
  return onSnapshot(query(collection(db, "proRequests"), orderBy("createdAt", "desc"), limit(500)), (snap) => {
    onChange(snap.docs.map((d) => ({
      id: d.id,
      status: d.get("status") as RequestStatus,
      name: d.get("name") as string,
      email: d.get("email") as string,
      telegram: (d.get("telegram") as string | null) ?? null,
      phone: (d.get("phone") as string | null) ?? null,
      created_at: toIso(d.get("createdAt")),
      decided_at: toIso(d.get("decidedAt")),
      decided_by: (d.get("decidedBy") as string | null) ?? null,
    })));
  }, onError);
}

/// Approve / reject / revoke goes through the server so the bot message is
/// updated too.
export const decideRequest = (id: string, action: "approve" | "reject" | "revoke") =>
  callApp<{ status: RequestStatus; changed: boolean }>("/admin/requests/decide", { id, action });

export interface TelegramStatus {
  configured: boolean; chatId: string | null; bot: { username: string; name: string } | null;
  webhookUrl: string | null; expectedUrl: string; pending: number; lastError: string | null;
}
export const telegramStatus = () => callApp<TelegramStatus>("/admin/telegram/status");
export const telegramConnect = () => callApp<{ ok: boolean }>("/admin/telegram/connect");

export async function fetchDevices(userId: string) {
  const snap = await getDocs(query(collection(db, "devices"), where("userId", "==", userId)));
  return snap.docs.map((d) => ({
    token_hash: d.id,
    platform: (d.get("platform") as string | null) ?? null,
    created_at: toIso(d.get("createdAt")) ?? "",
    last_seen: toIso(d.get("lastSeen")) ?? "",
    revoked_at: toIso(d.get("revokedAt")),
  })).sort((a, b) => b.last_seen.localeCompare(a.last_seen));
}

export const revokeDevice = (hash: string) => updateDoc(doc(db, "devices", hash), { revokedAt: serverTimestamp() });

export async function fetchGrants() {
  const snap = await getDocs(query(collection(db, "grants"), orderBy("createdAt", "desc")));
  return snap.docs.map((d) => ({
    id: d.id,
    email: d.get("email") as string,
    note: (d.get("note") as string | null) ?? null,
    expires_at: toIso(d.get("expiresAt")),
    created_by: d.get("createdBy") as string,
    created_at: toIso(d.get("createdAt")) ?? "",
    revoked_at: toIso(d.get("revokedAt")),
    request_id: (d.get("requestId") as string | null) ?? null,
  }));
}

export const revokeGrant = (id: string) =>
  updateDoc(doc(db, "grants", id), { revokedAt: serverTimestamp(), revokedBy: me() });

/// One active grant per email: ends the previous ones, then adds the new one.
export async function giveGrant(email: string, expiresAt: Date | null, note: string | null) {
  const clean = email.trim().toLowerCase();
  const active = await getDocs(query(collection(db, "grants"), where("email", "==", clean), where("revokedAt", "==", null)));
  await Promise.all(active.docs.map((d) => revokeGrant(d.id)));
  await addDoc(collection(db, "grants"), {
    email: clean,
    note,
    expiresAt: expiresAt ? Timestamp.fromDate(expiresAt) : null,
    createdBy: me(),
    createdAt: serverTimestamp(),
    revokedAt: null,
  });
}

export async function fetchInstalls() {
  const snap = await getDocs(query(collection(db, "installs"), orderBy("lastSeen", "desc"), limit(500)));
  return snap.docs.map((d) => ({
    install_id: d.id,
    user_id: (d.get("userId") as string | null) ?? null,
    platform: (d.get("platform") as string) ?? "unknown",
    os_version: (d.get("osVersion") as string | null) ?? null,
    app_version: (d.get("appVersion") as string | null) ?? null,
    first_seen: toIso(d.get("firstSeen")) ?? "",
    last_seen: toIso(d.get("lastSeen")) ?? "",
    launches: (d.get("launches") as number) ?? 0,
  }));
}

export async function fetchAdmins() {
  const snap = await getDocs(collection(db, "admins"));
  return snap.docs.map((d) => ({ email: d.id, added_at: toIso(d.get("addedAt")) ?? "" }))
    .sort((a, b) => a.added_at.localeCompare(b.added_at));
}

export async function addAdmin(email: string) {
  const ref = doc(db, "admins", email.trim().toLowerCase());
  if ((await getDoc(ref)).exists()) throw new Error("Already an admin.");
  await setDoc(ref, { addedAt: serverTimestamp(), addedBy: me() });
}

export const removeAdmin = (email: string) => deleteDoc(doc(db, "admins", email));
