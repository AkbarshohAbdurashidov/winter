// RevenueCat webhook -> `subscriptions` (Pro status per customer) and
// `revenuecat_events` (audit log). Configure in RevenueCat: Integrations ->
// Webhooks, URL `<SUPABASE_URL>/functions/v1/revenuecat-webhook`,
// Authorization header = the REVENUECAT_WEBHOOK_AUTH secret.
import {
  adminClient, ENTITLEMENT, env, isUuid, json, refreshFromRevenueCat, safeEqual,
  type SubscriptionRow,
} from "../_shared/pro.ts";

const db = adminClient();

const GRANTING = new Set([
  "INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE",
  "SUBSCRIPTION_EXTENDED", "NON_RENEWING_PURCHASE",
]);
const PAID = new Set(["INITIAL_PURCHASE", "RENEWAL", "NON_RENEWING_PURCHASE", "CANCELLATION"]);

/// Our customers are Supabase user ids; pick that one among the ids the
/// event carries (anonymous RevenueCat ids are ignored).
function customerId(e: any): string | null {
  const ids = [e.app_user_id, e.original_app_user_id, ...(e.aliases ?? [])];
  return ids.find(isUuid) ?? null;
}

const ms = (v: unknown) => (typeof v === "number" ? new Date(v).toISOString() : null);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const secret = env("REVENUECAT_WEBHOOK_AUTH");
  const auth = req.headers.get("Authorization") ?? "";
  if (!secret || !(safeEqual(auth, secret) || safeEqual(auth, `Bearer ${secret}`))) {
    return json({ error: "unauthorized" }, 401);
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "json" }, 400);
  }
  const e = payload?.event;
  if (!e?.id || !e?.type) return json({ error: "event" }, 400);

  const userId = customerId(e);
  const { error: dup } = await db.from("revenuecat_events").insert({
    id: e.id, type: e.type, app_user_id: userId ?? e.app_user_id ?? null, payload,
  });
  if (dup) {
    if (dup.code === "23505") return json({ ok: true, duplicate: true }); // retried delivery
    console.error("store event", dup);
    return json({ error: "store" }, 500); // RevenueCat retries
  }
  if (e.type === "TEST" || !userId) return json({ ok: true, ignored: true });
  const ents: string[] | null = e.entitlement_ids ?? (e.entitlement_id ? [e.entitlement_id] : null);
  if (ents && !ents.includes(ENTITLEMENT)) return json({ ok: true, ignored: true });

  const { data: existing } = await db.from("subscriptions").select("*")
    .eq("app_user_id", userId).maybeSingle();
  const period = typeof e.period_type === "string" ? e.period_type.toUpperCase() : null;
  const row: SubscriptionRow = {
    status: "none",
    revenue_usd: 0,
    had_trial: false,
    converted_from_trial: false,
    billing_issue: false,
    ...existing,
    app_user_id: userId,
    last_event: e.type,
    updated_at: new Date().toISOString(),
  };

  if (GRANTING.has(e.type)) {
    const expires = ms(e.expiration_at_ms);
    row.status = expires === null ? "lifetime" : period === "TRIAL" ? "trial" : "active";
    row.product_id = e.new_product_id ?? e.product_id ?? row.product_id;
    row.period_type = period;
    row.purchased_at = ms(e.purchased_at_ms) ?? row.purchased_at;
    row.expires_at = expires;
    row.will_renew = expires !== null;
    row.billing_issue = false;
  } else if (e.type === "CANCELLATION") {
    row.will_renew = false;
    if (e.cancel_reason === "CUSTOMER_SUPPORT") row.status = "refunded";
  } else if (e.type === "EXPIRATION") {
    row.status = "expired";
    row.will_renew = false;
  } else if (e.type === "BILLING_ISSUE") {
    row.billing_issue = true;
  }
  if (e.store) row.store = e.store;
  if (e.environment) row.environment = e.environment;
  if (period === "TRIAL") row.had_trial = true;
  if (e.is_trial_conversion === true) row.converted_from_trial = true;
  if (PAID.has(e.type) && typeof e.price === "number" && e.price !== 0) {
    row.revenue_usd = Math.round((Number(row.revenue_usd ?? 0) + e.price) * 100) / 100;
  }

  const { error } = await db.from("subscriptions").upsert(row);
  if (error) {
    console.error("store subscription", error);
    return json({ error: "store" }, 500);
  }
  // The RevenueCat API is the source of truth for the current state; the
  // event above already covers revenue/trial history.
  await refreshFromRevenueCat(db, userId);
  return json({ ok: true });
});
