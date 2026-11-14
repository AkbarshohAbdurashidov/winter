# Winter Pro: accounts, payments and the admin panel

```
 Winter app (Mac/Win)          Web portal (portal/, Firebase Hosting)     RevenueCat
 ───────────────────           ──────────────────────────────────────     ──────────
 ❄ menu: Sign In… ──opens──▶  /link?code=…  Google or email-link sign-in
                               approves the code
 polls /link/poll ◀── device token
 ❄ menu: Get Winter Pro… ───▶ /upgrade  RevenueCat Web Paywall ─────────▶ checkout (card,
                                         (Monthly/Yearly/Lifetime)         Apple Pay, Google Pay)
                               /account  status, computers,
                                         Manage subscription ───────────▶ customer portal
 /status every 30 min                                                          │ webhook
        │                                                                      ▼
        └──────────▶ Cloud Functions `app`, `revenuecatWebhook` + Firestore
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

## 1. Firebase

1. Create a project at console.firebase.google.com and switch it to the **Blaze** plan.
   Cloud Functions need it; a small app normally stays within the free quota.
2. **Authentication** → Sign-in method: enable **Google**, and **Email/Password** with
   **Email link (passwordless sign-in)** turned on. Under Settings → Authorized domains,
   add your portal's domain (`<project>.web.app` is already there).
3. **Firestore**: create the database in production mode (region e.g. `europe-west1`).
4. Add a **Web app** (Project settings → Your apps). Its config values go into
   `portal/.env.local` (see `portal/.env.example`).
5. Deploy from the repo root. The npm CLI is needed; the standalone CLI's bundled Node 20
   is too old for firebase-admin 14.
   ```sh
   npx firebase-tools@15 login
   npx firebase-tools@15 use --add            # pick your project
   npx firebase-tools@15 functions:secrets:set REVENUECAT_SECRET_KEY    # RevenueCat secret API key (v1)
   npx firebase-tools@15 functions:secrets:set REVENUECAT_WEBHOOK_AUTH  # any long random string
   printf 'PORTAL_URL=https://<project>.web.app\n' > firebase/functions/.env.<project>
   (cd portal && npm install && npm run build)
   npx firebase-tools@15 deploy                # functions + Firestore rules + portal hosting
   ```
   The deploy prints the function URLs, e.g. `https://europe-west1-<project>.cloudfunctions.net/app`.
   Put that URL into `VITE_API_URL`, then rebuild and redeploy the portal
   (`npx firebase-tools@15 deploy --only hosting`).
6. **First admin**: in Firestore, create the collection `admins` with a document whose ID is
   your email in lower case (field `addedAt` = now). After that, add more admins in the panel.

## 2. RevenueCat

1. Create a project, then add a **Web Billing** app and connect Stripe.
2. **Products**:
   - `monthly`: subscription, 1 month (optionally with a free trial).
   - `yearly`: subscription, 1 year (e.g. a 7-day free trial).
   - `lifetime`: one-time purchase (non-consumable).
3. **Entitlement** `winter_pro`: attach all three products.
4. **Offering** `default` (mark it Current), with packages:
   - `$rc_monthly` → `monthly`
   - `$rc_annual` → `yearly`
   - `$rc_lifetime` → `lifetime`
5. **Paywall**: create one for the `default` offering. The portal shows it with `presentPaywall`.
6. **API keys**:
   - Web Billing **public** key → `VITE_REVENUECAT_WEB_KEY`.
   - A **secret** key (REST API v1) → the `REVENUECAT_SECRET_KEY` secret.

   The `test_…` key is for the Test Store in the mobile SDKs and isn't used here. For
   testing, use the Web Billing **sandbox** key and Stripe test cards.
7. **Webhook** (Integrations → Webhooks):
   - URL: `https://europe-west1-<project>.cloudfunctions.net/revenuecatWebhook`
   - Authorization header: the `REVENUECAT_WEBHOOK_AUTH` value.
   - Send a test event. It should return 200.
8. **Apple Pay / Google Pay**: turn them on in Stripe (Settings → Payment methods). For
   Apple Pay, register the portal's domain in Stripe (Payment method domains).

## 3. App builds

```sh
WINTER_API_URL=https://europe-west1-<project>.cloudfunctions.net/app scripts/build_macos_dmg.sh
flutter build windows --release --dart-define=WINTER_API_URL=https://europe-west1-<project>.cloudfunctions.net/app
```

In GitHub, set the repository **variable** `WINTER_API_URL` (Settings → Secrets and
variables → Actions → Variables). The CI installers then include accounts. Never put the
RevenueCat secret key in the app.

## Local development / tests

```sh
npx firebase-tools@15 emulators:start --only auth,firestore,functions --project demo-winter
python3 firebase/tests/e2e.py      # 43 checks: sign-in, linking, grants, webhook, security rules
cd portal && npm run dev           # .env.local with VITE_USE_EMULATORS=true (see .env.example)
flutter run -d macos --dart-define=WINTER_API_URL=http://127.0.0.1:5001/demo-winter/europe-west1/app
```

Local secrets live in `firebase/functions/.secret.local` (`REVENUECAT_WEBHOOK_AUTH=local-webhook-secret`,
`REVENUECAT_SECRET_KEY=unset`). Sign-in links appear in the Auth emulator
(http://127.0.0.1:4000/auth); the emulator's Google popup accepts any test account.

## How access is decided (server, `firebase/functions/src/pro.ts`)

1. An active **free grant** for the user's email (given in the panel; can have an end
   date) → Pro.
2. Otherwise the `winter_pro` entitlement from RevenueCat → Pro while it's a trial, an
   active subscription (also after cancelling, until the period ends), or lifetime. It's
   kept current by the webhook, re-read from the RevenueCat API when older than 15 minutes,
   and refreshed right after a purchase.

The app caches the answer, so Pro keeps working offline for up to 14 days. A subscription
whose period ended needs a fresh check.
