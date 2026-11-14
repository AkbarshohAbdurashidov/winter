import { initializeApp } from "firebase/app";
import { connectAuthEmulator, getAuth } from "firebase/auth";
import { connectFirestoreEmulator, getFirestore, Timestamp } from "firebase/firestore";

export const config = {
  firebase: {
    apiKey: import.meta.env.VITE_FIREBASE_API_KEY as string,
    authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN as string,
    projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID as string,
    appId: import.meta.env.VITE_FIREBASE_APP_ID as string,
  },
  /// The `app` Cloud Function, e.g. https://europe-west1-<project>.cloudfunctions.net/app
  apiUrl: ((import.meta.env.VITE_API_URL as string) || "").replace(/\/+$/, ""),
  useEmulators: import.meta.env.VITE_USE_EMULATORS === "true",
  downloadMac: (import.meta.env.VITE_DOWNLOAD_MAC as string) || "#",
  downloadWindows: (import.meta.env.VITE_DOWNLOAD_WINDOWS as string) || "#",
};

export const firebaseApp = initializeApp(config.firebase);
export const auth = getAuth(firebaseApp);
export const db = getFirestore(firebaseApp);
if (config.useEmulators) {
  connectAuthEmulator(auth, "http://127.0.0.1:9099", { disableWarnings: true });
  connectFirestoreEmulator(db, "127.0.0.1", 8080);
}

export type Access = "pro" | "none";
export type RequestStatus = "pending" | "approved" | "rejected" | "revoked";

export interface ProRequest {
  id: string;
  status: RequestStatus;
  name: string;
  email: string;
  telegram: string | null;
  phone: string | null;
  created_at: string | null;
  decided_at: string | null;
  decided_by: string | null;
}

export interface AccountInfo {
  signedIn: boolean;
  email: string | null;
  userId: string;
  pro: boolean;
  access: Access;
  expiresAt: string | null;
  grantNote?: string | null;
  request: ProRequest | null;
  upgradeUrl: string;
  isAdmin: boolean;
  devices: { token_hash: string; platform: string | null; created_at: string; last_seen: string }[];
}

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

/// Calls the `app` Cloud Function as the signed-in user.
export async function callApp<T>(path: string, body: unknown = {}): Promise<T> {
  const token = await auth.currentUser?.getIdToken();
  const res = await fetch(`${config.apiUrl}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError(res.status, data?.error ?? res.statusText);
  return data as T;
}

/// Firestore Timestamp (or ISO string) -> ISO string.
export const toIso = (v: unknown): string | null =>
  v instanceof Timestamp ? v.toDate().toISOString() : typeof v === "string" ? v : null;

export const accessLabel: Record<Access, string> = {
  pro: "Winter Pro",
  none: "Free",
};

export const requestLabel: Record<RequestStatus, string> = {
  pending: "Pending",
  approved: "Approved",
  rejected: "Rejected",
  revoked: "Pro removed",
};

export function formatDate(iso: string | null | undefined, withTime = false): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return withTime
    ? d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })
    : d.toLocaleDateString(undefined, { dateStyle: "medium" });
}

export function timeAgo(iso: string | null | undefined): string {
  if (!iso) return "never";
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  if (s < 86400 * 30) return `${Math.floor(s / 86400)} d ago`;
  return formatDate(iso);
}
