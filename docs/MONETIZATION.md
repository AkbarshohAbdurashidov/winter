# Winter Pro: accounts, Pro requests, Telegram bot and the admin panel

```
 Winter app (Mac/Win)          Web portal (portal/, Firebase Hosting)      Telegram bot (admin chat)
 ───────────────────           ──────────────────────────────────────      ─────────────────────────
 ❄ menu: Sign In… ──opens──▶  /link?code=…  Google or email-link sign-in ──▶ 👋 new user
 polls /link/poll ◀── device token
 ❄ menu: Get Winter Pro… ───▶ /upgrade  form: name*, email* (= the        ──▶ ❄️ Pro request
                                         account), Telegram, phone            [✅ Tasdiqlash] [❌ Rad etish]
                               /admin   Pro requests (live), Users,        ◀─▶ same buttons, same state
                                         Give Pro, Installs, Admins
 /status every 30 min ◀────── Cloud Functions `app`, `telegramWebhook`, `onGrantUpdated` + Firestore
```

**How Pro works.** Pro belongs to an **email**. It's on while the email has an active
document in `grants` (forever, or until a date). A grant is created when an admin
approves a Pro request (in the panel or the bot) or gives Pro directly in **Give Pro**
(this works even before the person signs up). The app signs in with that email and
sees Pro within 30 minutes, or right away with ❄ → Refresh Pro Status.

**Sync between the panel and the bot.** Every approve / reject / remove goes through one
server function (`decideRequest` in `firebase/functions/src/telegram.ts`). It changes
Firestore, then edits the request's bot message (text + buttons). The panel shows requests
with a live Firestore listener, so a press in Telegram appears in the panel without a
reload. Removing a request's Pro in **Give Pro** or the user drawer also marks the request
"Pro bekor qilindi" in the bot (the `onGrantUpdated` trigger). If both sides press at the
same time, the second press is a no-op ("Holat allaqachon o'zgargan").

**Pro unlocks:** Heavy and Blizzard snowfall, High and Ultra quality. Change the sets in
`OverlayController.proIntensities` / `proQualities`. Everything else stays free.
A build without `WINTER_API_URL` has no account features and nothing is locked.

**Data collected** (for the admin panel): a random install id, platform, OS version, app
version, first/last seen, launch count, and the email of signed-in users. A Pro request also
stores the name and, if given, the Telegram username and phone number, and sends them to
the admin Telegram chat. Mention this in your privacy policy.

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
   npx firebase-tools@15 use --add                                     # pick your project
   npx firebase-tools@15 functions:secrets:set TELEGRAM_BOT_TOKEN      # from @BotFather
   npx firebase-tools@15 functions:secrets:set TELEGRAM_WEBHOOK_SECRET # any long random string: openssl rand -hex 32
   printf 'PORTAL_URL=https://<project>.web.app\nTELEGRAM_CHAT_ID=<chat id>\n' > firebase/functions/.env.<project>
   (cd portal && npm install && npm run build)
   npx firebase-tools@15 deploy                # functions + Firestore rules + portal hosting
   ```
   The deploy prints the function URLs, e.g. `https://europe-west1-<project>.cloudfunctions.net/app`.
   Put that URL into `VITE_API_URL`, then rebuild and redeploy the portal
   (`npx firebase-tools@15 deploy --only hosting`).
6. **First admin**: in Firestore, create the collection `admins` with a document whose ID is
   your email in lower case (field `addedAt` = now). After that, add more admins in the panel.

## 2. Telegram bot

1. Create the bot with @BotFather (`/newbot`); the token goes into the `TELEGRAM_BOT_TOKEN`
   secret. Never commit it: the repo is public.
2. **Chat id**: the chat that gets the notifications. For a private chat, it's your own user
   id. You can also add the bot to a group and use the group's id (negative). After step 3,
   send `/id` to the bot in that chat and it replies with the id.
3. Open the admin panel → **Pro requests** → **Connect buttons**. This registers the
   `telegramWebhook` URL with Telegram (with the secret), so the inline buttons work. The card
   shows **Connected** when done. Notifications work even without this step; only the
   buttons need it.
4. Only presses from `TELEGRAM_CHAT_ID` are accepted. Anyone in that chat can approve, and the
   panel shows who did (`telegram:@username`).
5. **Several apps, one bot.** Messages say `❄️ Winter uchun Pro so'rov #winter`. Buttons carry
   `winter:<id>:<action>`. Telegram has one webhook per bot, so Winter receives every press and
   forwards other apps' presses (`<appId>:…`) to the URLs in `TELEGRAM_ROUTES`
   (`appId=https://…/telegramWebhook`, in `.env.<project>`), with the same webhook secret.
   Settings: `APP_ID`, `APP_NAME`. To add another app, see [PRO_SYSTEM_PROMPT.md](PRO_SYSTEM_PROMPT.md).

## 3. App builds

```sh
WINTER_API_URL=https://europe-west1-<project>.cloudfunctions.net/app scripts/build_macos_dmg.sh
flutter build windows --release --dart-define=WINTER_API_URL=https://europe-west1-<project>.cloudfunctions.net/app
```

In GitHub, set the repository **variable** `WINTER_API_URL` (Settings → Secrets and
variables → Actions → Variables). The CI installers then include accounts.

## Local development / tests

```sh
npx firebase-tools@15 emulators:start --only auth,firestore,functions --project demo-winter
python3 firebase/tests/e2e.py      # 72 checks, with a fake Telegram API on 127.0.0.1:8765
cd portal && npm run dev           # .env.local with VITE_USE_EMULATORS=true (see .env.example)
flutter run -d macos --dart-define=WINTER_API_URL=http://127.0.0.1:5001/demo-winter/europe-west1/app
```

Local settings (both gitignored):
- `firebase/functions/.secret.local`:
  `TELEGRAM_BOT_TOKEN=<token or anything>`, `TELEGRAM_WEBHOOK_SECRET=local-telegram-secret`.
- `firebase/functions/.env.local`: `PORTAL_URL=http://localhost:5173`, `TELEGRAM_CHAT_ID=…`.
  For e2e.py, also `TELEGRAM_API=http://127.0.0.1:8765` and `TELEGRAM_CHAT_ID=1000`. Without
  `TELEGRAM_API` the emulator sends real messages to your bot. The buttons can't reach a local
  emulator, but e2e.py posts the same updates Telegram would.

Sign-in links appear in the Auth emulator (http://127.0.0.1:4000/auth). The emulator's Google
popup accepts any test account.
