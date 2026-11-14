# Winter Pro: accounts, payments and the admin panel

```
 Winter app (Mac/Win)          Web portal (portal/)                     RevenueCat
 ───────────────────           ─────────────────                     ──────────
 ❄ menu: Sign In… ──opens──▶  /link?code=…  email code sign-in
                               approves the code
 polls /link/poll ◀── device token
 ❄ menu: Get Winter Pro… ───▶ /upgrade  RevenueCat Web Paywall ───▶ checkout (card,
                                         (Monthly/Yearly/Lifetime)    Apple Pay, Google Pay)
                               /account  status, computers,
                                         Manage subscription ──────▶ customer portal
 /status every 30 min                                                     │ webhook
        │                                                                 ▼
        └──────────▶ Supabase: edge functions `app`, `revenuecat-webhook` + Postgres
                     /admin (portal/) reads it: users, trials, buyers, free access
```

Why the web and not the in-app SDK: RevenueCat's Paywall and Customer Center UI
(`purchases_ui_flutter`) support iOS/Android only. The SDK doesn't support Windows, and
App Store purchases in a DMG distributed outside the Mac App Store aren't documented as
working. RevenueCat **Web Billing** works the same on both platforms, and its paywall
offers Apple Pay and Google Pay where the browser supports them.

**Pro unlocks:** Heavy and Blizzard snowfall, High and Ultra quality. Change the sets in
`OverlayController.proIntensities` / `proQualities`. Everything else stays free.
A build without `WINTER_API_URL` has no account features and nothing is locked.

**Data collected** (for the admin panel): a random install id, platform, OS version, app
version, first/last seen, launch count, and the email of signed-in users. No IP addresses
and no names. Mention this in your privacy policy.

## 1. Supabase

1. Create a project at supabase.com. Note the **Project URL** and **anon key**
   (Settings → API).
2. Deploy the database and functions:
   ```sh
   cd backend
   supabase link --project-ref <ref>
   supabase db push
   supabase functions deploy app revenuecat-webhook --no-verify-jwt
   ```
3. Secrets (Settings → Edge Functions, or the CLI):
   ```sh
   supabase secrets set \
     PORTAL_URL=https://winter.example.com \
     REVENUECAT_SECRET_KEY=sk_... \
     REVENUECAT_WEBHOOK_AUTH=$(openssl rand -hex 24) \
     REVENUECAT_PURCHASE_LINK=https://pay.rev.cat/<token>   # optional fallback
   ```
4. Auth → URL Configuration: set **Site URL** = `PORTAL_URL`, and add
   `PORTAL_URL/**` to the redirect URLs.
5. Auth → Email Templates → **Magic Link**: paste
   `backend/supabase/templates/sign_in.html` (it contains the 6-digit code `{{ .Token }}`).
6. Auth → SMTP: set up your own SMTP provider (e.g. Resend or Postmark). Supabase's
   built-in mailer sends only a few emails per hour.
7. Make yourself an admin (SQL editor):
   `insert into public.admins(email) values ('you@example.com');`
   After that, add more admins in the panel.

## 2. RevenueCat

1. Create a project, then add a **Web Billing** app and connect Stripe.
2. **Products** (Web Billing app → Products):
   - `monthly`: subscription, 1 month (optionally with a free trial).
   - `yearly`: subscription, 1 year (e.g. a 7-day free trial).
   - `lifetime`: one-time purchase (non-consumable).
3. **Entitlement** `winter_pro`: attach all three products.
4. **Offering** `default` (mark it Current), with packages:
   - `$rc_monthly` → `monthly`
   - `$rc_annual` → `yearly`
   - `$rc_lifetime` → `lifetime`
5. **Paywall**: create one for the `default` offering. The web portal shows it with
   `presentPaywall`.
6. **API keys**:
   - Web Billing **public** key → `VITE_REVENUECAT_WEB_KEY`.
   - A **secret** key (REST API v1) → `REVENUECAT_SECRET_KEY`.

   The `test_…` key is for the Test Store in the mobile SDKs and isn't used here. For
   testing, use the Web Billing **sandbox** key and Stripe test cards.
7. **Webhook** (Integrations → Webhooks):
   - URL: `https://<ref>.supabase.co/functions/v1/revenuecat-webhook`
   - Authorization header: the `REVENUECAT_WEBHOOK_AUTH` value.
   - Send a test event. It should return 200.
8. **Apple Pay / Google Pay**: turn them on in Stripe (Settings → Payment methods). For
   Apple Pay, register the portal's domain in Stripe (Payment method domains).
9. (Optional) Funnels → Purchase Links: copy the production link for
   `REVENUECAT_PURCHASE_LINK` / `VITE_REVENUECAT_PURCHASE_LINK`. It's used when no web key
   is set.

## 3. Web portal + admin panel (`portal/`)

```sh
cd portal
cp .env.example .env.local   # fill in the Supabase URL/anon key and the RevenueCat web key
npm install && npm run dev   # http://localhost:5173
npm run build                # static files in portal/dist
```

Deploy `portal/dist` to any static host. `vercel.json` (Vercel) and `public/_redirects`
(Cloudflare Pages, Netlify) send every route to the app. Set the same `VITE_*` variables
in the host's settings. Pages:
- `/admin`: the panel (admins only; enforced by database RLS, not just the UI).
- `/account`: the customer's status, computers, and subscription management.
- `/upgrade`: the paywall.
- `/link`: used by the app's "Sign In…".

## 4. App builds

```sh
WINTER_API_URL=https://<ref>.supabase.co/functions/v1/app WINTER_API_KEY=<anon key> \
  scripts/build_macos_dmg.sh
flutter build windows --release --dart-define=WINTER_API_URL=... --dart-define=WINTER_API_KEY=...
```

In GitHub, set the repository **variables** `WINTER_API_URL` and `WINTER_API_KEY`
(Settings → Secrets and variables → Actions → Variables). The CI installers then include
accounts. Both values are public by design; never put the RevenueCat secret key or the
Supabase service key in the app.

## Local development / tests

```sh
cd backend && supabase start
supabase functions serve --env-file <file with PORTAL_URL and REVENUECAT_WEBHOOK_AUTH=local-webhook-secret>
python3 tests/e2e.py        # 38 checks: sign-in, linking, grants, webhook, RLS
flutter run -d macos --dart-define=WINTER_API_URL=http://127.0.0.1:54321/functions/v1/app
```

Sign-in emails go to Mailpit at http://127.0.0.1:54324.

## How access is decided (server, `functions/_shared/pro.ts`)

1. An active **free grant** for the user's email (given in the panel; can have an end
   date) → Pro.
2. Otherwise the `winter_pro` entitlement from RevenueCat → Pro while it's a trial, an
   active subscription (also after cancelling, until the period ends), or lifetime. It's
   kept current by the webhook, re-read from the RevenueCat API when older than 15 minutes,
   and refreshed right after a purchase.

The app caches the answer, so Pro keeps working offline for up to 14 days. A subscription
whose period ended needs a fresh check.
