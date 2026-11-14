import { createClient, type Session } from "@supabase/supabase-js";

export const config = {
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL as string,
  supabaseAnonKey: import.meta.env.VITE_SUPABASE_ANON_KEY as string,
  revenueCatWebKey: (import.meta.env.VITE_REVENUECAT_WEB_KEY as string) || "",
  purchaseLink: ((import.meta.env.VITE_REVENUECAT_PURCHASE_LINK as string) || "").replace(/\/+$/, ""),
  downloadMac: (import.meta.env.VITE_DOWNLOAD_MAC as string) || "#",
  downloadWindows: (import.meta.env.VITE_DOWNLOAD_WINDOWS as string) || "#",
};

export const supabase = createClient(config.supabaseUrl, config.supabaseAnonKey);

export type Access = "free" | "trial" | "active" | "lifetime" | "expired" | "refunded" | "none";

export interface AccountInfo {
  signedIn: boolean;
  email: string | null;
  userId: string;
  pro: boolean;
  access: Access;
  productId: string | null;
  expiresAt: string | null;
  willRenew: boolean | null;
  hadTrial: boolean;
  manageUrl: string | null;
  grantNote?: string | null;
  upgradeUrl: string;
  isAdmin: boolean;
  devices: { token_hash: string; platform: string | null; created_at: string; last_seen: string }[];
}

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

/// Calls the `app` edge function as the signed-in user.
export async function callApp<T>(path: string, body: unknown = {}, session?: Session | null): Promise<T> {
  const s = session ?? (await supabase.auth.getSession()).data.session;
  const res = await fetch(`${config.supabaseUrl}/functions/v1/app${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: config.supabaseAnonKey,
      ...(s ? { Authorization: `Bearer ${s.access_token}` } : {}),
    },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError(res.status, data?.error ?? res.statusText);
  return data as T;
}

export const accessLabel: Record<Access, string> = {
  free: "Free access",
  trial: "Free trial",
  active: "Subscribed",
  lifetime: "Lifetime",
  expired: "Expired",
  refunded: "Refunded",
  none: "Not subscribed",
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
