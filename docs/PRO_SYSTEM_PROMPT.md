# Pro so'rov tizimi: boshqa dastur uchun prompt

> **Bu fayl nima?** Winter'dagi Pro tizimini (akkaunt, "Pro so'rov" formasi, Telegram bot,
> admin panel) boshqa dasturga o'rnatish uchun tayyor prompt.
>
> **Qanday ishlatiladi:**
> 1. Pastdagi `{{...}}` qiymatlarni to'ldiring.
> 2. "PROMPT" bo'limini to'liq nusxalab, yangi dastur loyihasida AI agentga bering.
> 3. Oxiridagi "Ishga tushirish" ro'yxatini bajaring.
>
> **Bitta bot, bir nechta dastur.** Ikkala dastur ham bitta bot (@winter_admin_bot) va bitta
> chatdan foydalanadi. Har bir xabar qaysi dasturdan kelganini ko'rsatadi:
> `❄️ Winter uchun Pro so'rov #winter` va `🎵 {{APP_NAME}} uchun Pro so'rov #{{APP_ID}}`.
>
> Telegram bitta botga faqat **bitta** webhook beradi, shuning uchun hamma tugma bosishlar
> avval Winter'ga keladi. Winter tugmadagi prefiksdan (`{{APP_ID}}:...`) qaysi dastur
> ekanini aniqlaydi va bosishni o'sha dasturning webhook'iga uzatadi.
>
> Bu ishlashi uchun Winter'ning `TELEGRAM_ROUTES` sozlamasiga yangi dastur qo'shiladi.
> Yangi dastur esa webhook'ni o'zi hech qachon o'rnatmaydi.

| O'zgaruvchi | Ma'nosi | Misol |
|---|---|---|
| `{{APP_NAME}}` | Xabarlarda va saytda ko'rinadigan nom | `Focus Timer` |
| `{{APP_ID}}` | Qisqa id: kichik harf, raqam, `_`, `-`, 16 belgigacha. **`winter` va `req` bo'lmasin** | `focus` |
| `{{EMOJI}}` | Bot xabaridagi belgi | `⏱️` |
| `{{PRO_FEATURES}}` | Pro nimani ochadi | `Cheksiz sessiyalar, statistika eksporti` |
| `{{PLATFORM}}` | Dastur turi | `Flutter desktop (macOS + Windows)` / `Android` / `web` |
| `{{FIREBASE_PROJECT}}` | Yangi dastur uchun Firebase loyiha | `focus-timer-app` |

---

## PROMPT

````text
You are adding a "Pro by request" system to {{APP_NAME}} ({{PLATFORM}}). There is no payment
provider. A user signs in, fills in a short "leave your contact to get Pro" form, and an admin
approves or rejects the request, either in a web admin panel or with inline buttons in a
Telegram bot. Both places must always show the same state. Pro belongs to an EMAIL.

Stack: Firebase on the Blaze plan (Auth, Firestore, Cloud Functions v2 in TypeScript, region
europe-west1, Hosting) + a React/Vite/Tailwind web portal + the {{PLATFORM}} client.
Firebase project: {{FIREBASE_PROJECT}}. Use firebase-tools 15 via npx.

Pro unlocks: {{PRO_FEATURES}}. Everything else stays free. A client build without the API
URL has no account features and locks nothing.

Write clean, small, well-named code. Validate everything on the server. Never trust the client.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. SHARED TELEGRAM BOT (most important constraint)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
This app shares one bot and one admin chat with another app ("Winter"). Telegram allows
ONE webhook per bot, and Winter owns it. Winter forwards button presses whose callback_data
starts with "{{APP_ID}}:" to this app's `telegramWebhook` URL. It posts the unchanged
Telegram update JSON with the same `X-Telegram-Bot-Api-Secret-Token` header.

So:
- Config (functions params; NEVER commit secrets, the repo may be public):
  - secrets: TELEGRAM_BOT_TOKEN (same bot as Winter), TELEGRAM_WEBHOOK_SECRET (the SAME value
    Winter uses, so forwarded presses pass the same check).
  - strings: TELEGRAM_CHAT_ID (same chat as Winter), TELEGRAM_API (default
    https://api.telegram.org; tests point it at a fake server), APP_ID="{{APP_ID}}",
    APP_NAME="{{APP_NAME}}", PORTAL_URL, ADMIN_EMAILS (comma list, bootstrap admins),
    TELEGRAM_SHARED (default "true").
- When TELEGRAM_SHARED=true, this app must NEVER call setWebhook or setMyCommands.
  `/admin/telegram/connect` returns 409 "shared-bot", and the admin panel's Telegram card
  says "Shared bot: button presses arrive through Winter" instead of a Connect button.
  getMe/getWebhookInfo may still be shown read-only.
- If TELEGRAM_SHARED=false (own bot), implement Connect = setWebhook(url, secret_token,
  allowed_updates ["callback_query","message"]) + setMyCommands [{id, "Chat ID"}].
- Also implement TELEGRAM_ROUTES (format "appId=https://…/telegramWebhook,other=…"), the same
  as Winter, so this app can become the hub later. If a callback's appId is neither this
  APP_ID nor "req" and a route exists, POST the raw update there with the secret header and
  do nothing else. If that fetch fails, answerCallbackQuery "Dastur javob bermadi".

Bot message formats (HTML parse_mode, escape & < > in all user data, times in Asia/Tashkent):

  New user (sent once per uid, on first /hello):
    👋 <b>{{APP_NAME}}</b> · Yangi foydalanuvchi
    #{{APP_ID}}
    <name if any>
    📧 <email>

  Pro request (sendMessage, then store message_id + chat id on the request for edits):
    {{EMOJI}} <b>{{APP_NAME}} uchun Pro so'rov</b>
    #{{APP_ID}}

    👤 <b>Ism:</b> …
    📧 <b>Email:</b> …
    ✈️ <b>Telegram:</b> @username | —
    📞 <b>Telefon:</b> … | —
    🕒 <created at>

    Holat: ⏳ <b>Kutilmoqda</b> | ✅ <b>Tasdiqlandi</b> | ❌ <b>Rad etildi</b> | 🚫 <b>Pro bekor qilindi</b>
    <i>who decided · when</i>          (only when not pending)
    <code>requestId</code>

  Inline buttons, callback_data = "{{APP_ID}}:<requestId>:<action>" (≤ 64 bytes):
    pending  → [✅ Tasdiqlash (approve)] [❌ Rad etish (reject)]
    approved → [🚫 Pro'ni bekor qilish (revoke)]
    rejected / revoked → [✅ Tasdiqlash (approve)]

`telegramWebhook` (onRequest, secrets TOKEN + WEBHOOK_SECRET):
- Compare the header with the secret in constant time (timingSafeEqual); otherwise 401.
- Always answer 200 to valid calls, so Telegram never retries forever.
- For messages "/start" or "/id", reply "Chat ID: <code>…</code>". Only the hub does this; when
  TELEGRAM_SHARED=true, Winter already replies.
- Parse callback_data with /^([a-z0-9_-]{1,16}):([A-Za-z0-9]{1,40}):(approve|reject|revoke)$/.
  Accept it only if the appId is APP_ID and the chat id == TELEGRAM_CHAT_ID; otherwise answer
  "Ruxsat yo'q".
- actor = "telegram:@username" (or "telegram:<id>").
- Run decideRequest, then answerCallbackQuery with "✅ Pro berildi" / "❌ Rad etildi" /
  "🚫 Pro bekor qilindi" / "Holat allaqachon o'zgargan" (no-op) / "So'rov topilmadi".

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
2. DATA (Firestore)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
admins/{lowercase email}   addedAt, addedBy
users/{uid}                email, name, createdAt, lastSeenAt
grants/{auto}              email (lowercase), note, expiresAt|null, createdBy, createdAt,
                           revokedAt|null, revokedBy?, requestId?, revokedBySync?
proRequests/{auto}         userId, email, name, telegram|null (no @), phone|null,
                           status pending|approved|rejected|revoked, createdAt,
                           decidedAt, decidedBy, grantId, telegramMessageId, telegramChatId
installs/{installId}       platform, osVersion, appVersion, firstSeenAt, lastSeenAt, launches
devices/{sha256(token)}    userId, installId, platform, createdAt, lastSeenAt, revokedAt
deviceLinks/{sha256(code)} installId, userId, createdAt, approvedAt, consumedAt (TTL 10 min)

Pro rule (one function, accessFor(email)): Pro is on when the email has a grant with
revokedAt == null and (expiresAt == null or expiresAt > now). If there are several, pick the
one with the latest expiry (null = forever). The client receives access "pro" | "none" and expiresAt.

Security rules. Clients only READ; all writes go through Functions (Admin SDK), except:
- signedIn() means email_verified == true.
- admins: an admin reads all and a user reads their own doc. An admin creates new admins
  (keys addedAt, addedBy) and deletes them, but never themselves.
- grants: admin read. Admin create needs: lowercase email, createdBy == own email,
  revokedAt == null. Admin update may change only revokedAt / revokedBy, and revokedBy must
  be the admin's own email.
- proRequests: admin, or the owner (userId == auth.uid).
- users: admin or self. installs: admin. devices: admin or owner; admin may set revokedAt.
- Everything else is denied.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
3. ONE STATE MACHINE: decideRequest(id, decision, actor)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Every approve, reject or revoke goes through this function, whether it comes from the
panel or the bot.

It runs as a Firestore transaction:
  approve: pending|rejected|revoked → approved. Revoke every other active grant of that
           email, create a grant {email, note "Pro request (<name>)", expiresAt null,
           createdBy actor, requestId}, and store grantId on the request.
  reject:  pending → rejected
  revoke:  approved → revoked. Set the request's grant revokedAt = now and
           revokedBySync = true.
If the transition doesn't apply (for example, both sides pressed at once), nothing changes
and the result is { changed:false, status:<current> }.

After the transaction, if something changed, call editMessageText on the stored message
with the new text and buttons.

Firestore trigger onGrantUpdated(grants/{id}): when revokedAt goes from null to a value
and the grant has a requestId but not revokedBySync, mark that request revoked
(decidedBy = grant.revokedBy ?? "admin panel") and refresh the bot message.
This covers Pro removed from the panel's "Give Pro" tab or the user drawer.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
4. HTTP API: one onRequest function `app`, POST JSON, CORS for PORTAL_URL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Errors are { error: "<code>" } with a proper status. Portal calls send
"Authorization: Bearer <Firebase ID token>" and require a verified email. Admin = a doc in
admins/.

Device (no login; the app keeps a random installId and a device token in secure storage):
  /heartbeat {installId, platform, osVersion, appVersion} → upsert installs, launches++
  /link/start {code ≥32 chars, installId, next?} → { url: PORTAL/link?code=…[&next=upgrade] }
  /link/approve (ID token) {code} → binds the code to the signed-in uid
  /link/poll {code} → once approved, creates devices/{sha256(token)} and returns
               { token } once (consumedAt), else { pending:true }
  /status {token} → { signedIn, email, pro, access, expiresAt, upgradeUrl, accountUrl, checkedAt }
  /signout {token} → revoke that device
(For a web-only or mobile app with Firebase Auth inside the app, skip the link flow and call
/status with the ID token instead.)

Portal:
  /hello → creates users/{uid} on the first call and sends the "Yangi foydalanuvchi" bot
           message once. If the email is in ADMIN_EMAILS and admins/ is missing it, create
           the admin doc. Returns { admin }.
  /account → { email, pro, access, expiresAt, devices[], request (latest, any status) }
  /devices/revoke {tokenHash}
  /pro/request {name, telegram?, phone?} → the email ALWAYS comes from the ID token, never
       from the body. name is 2–80 chars after trim. telegram matches ^@?[A-Za-z0-9_]{4,32}$
       (store it without @). phone matches ^\+?[0-9 ()-]{7,20}$. Errors: 400 name|telegram|phone,
       409 already-pro, 409 pending (only one pending request per email). Creates the request,
       announces it in the bot and returns { ok, request }.

Admin (require admin, else 401/403):
  /admin/requests/decide {id, action approve|reject|revoke} → decideRequest(id, action, adminEmail)
  /admin/telegram/status → configured, chatId, bot username, webhookUrl, expectedUrl, pending
       updates, lastError, shared
  /admin/telegram/connect → see section 1
  /admin/users → rows: email, name, created, lastSeen, devices count, access, expiresAt,
       telegram, phone, request_status
  /admin/stats → installs, active (7d), users, pro, requests, pending, approved, rejected,
       revoked, platforms{}, versions{}, new_installs_14d[14]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
5. WEB PORTAL (React + Vite + Tailwind, Firebase Hosting, SPA rewrite)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Look: dark, calm and premium. Use glass cards (bg-white/5, ring-white/10, backdrop-blur),
one accent colour that fits {{APP_NAME}}, soft glow blobs, rounded-2xl, generous spacing,
and the system font stack. Every page must work at phone width.

Sign-in: Google popup, plus passwordless email link. Config comes from VITE_* env in a
gitignored .env.local; add an .env.example.

Pages:
- /link?code=…  Sign in, then "Connect this computer?" → /link/approve → "Done, return to the
  app". If next=upgrade, go on to /upgrade.
- /upgrade  Left column: title "Get {{APP_NAME}} Pro" and the perks list with check icons.
  Right card:
    • not signed in → sign-in card with "Sign in first — Pro is given to your account's email."
    • Pro → "You have {{APP_NAME}} Pro" (+ "Active until …"), plus how the app refreshes.
    • pending → "Request sent" badge, created time, and the submitted name/email/telegram/phone.
    • otherwise the form: Name* (prefilled with displayName), Email* (read-only, the account,
      hint "Pro is given to this email. Sign in with another account to use a different one."),
      Telegram (@username), Phone (+998 90 123 45 67). Use the same patterns as the server,
      button "Request {{APP_NAME}} Pro". If the previous request was rejected or revoked, show an
      info notice "You can send a new request". Map server error codes to friendly text.
- /account  email, Pro badge, latest request status, devices with "Sign out" each, links.
- /admin  (only for admins; call /hello first, then check admins/{email})
    Tabs:
    • Overview: stat cards plus a 14-day new-installs bar chart.
    • Pro requests: a LIVE onSnapshot list (newest first) with a pending-count badge on the
      tab. Cards show name, email, t.me/<user> link, tel: link, time, a status badge, and
      buttons Approve / Reject / Remove Pro (all through /admin/requests/decide). Include
      the Telegram card from section 1.
    • Users: search plus filters All / {{APP_NAME}} Pro / Waiting / Free, and a contact column.
      A row opens a drawer with details, devices and Approve / Reject / Remove Pro.
    • Give Pro: grant Pro to any email (forever or until a date, plus a note), even before
      sign-up. Show a list of active grants with Remove (sets revokedAt + revokedBy = own email).
    • Installs: platform, OS, version, last seen, launches.
    • Admins: add or remove (not yourself).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
6. CLIENT APP ({{PLATFORM}})
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- The API URL comes from a build define (e.g. --dart-define=APP_API_URL=…). If it is missing,
  account features are off and nothing is locked.
- On start, send /heartbeat. Call /status at launch, every 30 min, and from a
  "Refresh Pro Status" menu item. Cache the last status. Keep Pro offline until expiresAt
  if the last check said pro, and never past expiresAt.
- Menu: Sign In… (random 32+ char code → /link/start → open the URL in the browser → poll
  /link/poll every 2 s for up to 10 min), Get {{APP_NAME}} Pro… (/link/start with
  next=upgrade, or open /upgrade), Account…, Sign Out.
- Locked features show a small "Pro" tag and open the upgrade flow instead of switching on.
- Keep the token in secure storage (Keychain / DPAPI / Keystore).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
7. TESTS AND DELIVERY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- firebase/tests/e2e.py runs against the emulators (auth, firestore, functions, project
  demo-*). It starts a FakeTelegram HTTP server on 127.0.0.1:8765 that records Bot API calls,
  and uses .env.local TELEGRAM_API=http://127.0.0.1:8765, TELEGRAM_CHAT_ID=1000. Cover:
  - request validation, and that the email comes from the token not the body
  - the bot message text contains "{{APP_NAME}} uchun Pro so'rov" and "#{{APP_ID}}"; buttons
    are "{{APP_ID}}:<id>:approve|reject"
  - webhook rejects a bad secret (401) and ignores another chat
  - approve via the webhook makes /status pro; the edited message says Tasdiqlandi with a
    revoke button
  - a stale press is a no-op
  - panel revoke re-renders the message; removing a grant triggers the request revoked sync
  - reject then re-request; one pending at a time; already-pro 409
  - "winter:…" or unknown appIds are refused ("Ruxsat yo'q")
  - routing: a TELEGRAM_ROUTES entry forwards with the secret
  - /admin/telegram/connect returns 409 when shared
  - admin-only endpoints return 401/403; Firestore rules (user can't read others; grant update
    limited to revokedAt/revokedBy)
  - the new-user message is sent only once
- CI (GitHub Actions) runs tsc, the portal build and e2e.py with fake secrets written to
  .secret.local / .env.local.
- .gitignore: .secret.local, .env.*.local, .env.<project>, node_modules, dist.
- docs/PRO.md: setup steps and the data we collect (install id, platform, OS/app version,
  first/last seen, launches, emails, and the request name/telegram/phone sent to the admin
  Telegram chat) for the privacy policy.

When done, run the e2e tests and the builds, and report what passed.
````

---

## Ishga tushirish (siz bajarasiz)

**Yangi dastur ({{FIREBASE_PROJECT}}):**

1. Firebase loyiha oching va Blaze rejasini yoqing. Auth'da Google va Email link'ni yoqing.
   Firestore'ni `europe-west1` mintaqasida yarating.
2. Secret'larni o'rnating. Ikkalasi ham Winter'dagi bilan **bir xil** bo'lishi kerak:
   ```sh
   npx -y firebase-tools@15 --project {{FIREBASE_PROJECT}} functions:secrets:set TELEGRAM_BOT_TOKEN
   npx -y firebase-tools@15 --project {{FIREBASE_PROJECT}} functions:secrets:set TELEGRAM_WEBHOOK_SECRET
   ```
   Winter'dagi webhook secret'ni ko'rish uchun shu loyihada (winter) quyidagini ishga tushiring:
   `npx -y firebase-tools@15 --project winter-snow-app functions:secrets:access TELEGRAM_WEBHOOK_SECRET`
3. `firebase/functions/.env.{{FIREBASE_PROJECT}}` faylini yarating (gitignored):
   ```
   APP_ID={{APP_ID}}
   APP_NAME={{APP_NAME}}
   TELEGRAM_CHAT_ID=<Winter bilan bir xil chat id>
   TELEGRAM_SHARED=true
   PORTAL_URL=https://{{FIREBASE_PROJECT}}.web.app
   ADMIN_EMAILS=<sizning emailingiz>
   ```
4. Deploy qiling. Chiqqan `telegramWebhook` URL'ni yozib oling:
   `https://europe-west1-{{FIREBASE_PROJECT}}.cloudfunctions.net/telegramWebhook`

**Winter tomonida (bir marta):**

5. `firebase/functions/.env.winter-snow-app` fayliga quyidagi qatorni qo'shing:
   ```
   TELEGRAM_ROUTES={{APP_ID}}=https://europe-west1-{{FIREBASE_PROJECT}}.cloudfunctions.net/telegramWebhook
   ```
   Uchinchi dastur qo'shilsa, vergul bilan qo'shiladi: `a=https://…,b=https://…`.
6. Winter funksiyalarini qayta deploy qiling:
   `npx -y firebase-tools@15 --project winter-snow-app deploy --only functions:app,functions:telegramWebhook,functions:onGrantUpdated`

**Tekshirish:** yangi dasturda Pro so'rov yuboring. Botga `🎵 {{APP_NAME}} uchun Pro so'rov`
xabari kelishi kerak. "✅ Tasdiqlash" bosilganda yangi dasturning admin panelida holat
"Tasdiqlandi" bo'lishi kerak.

> ⚠️ Yangi dastur admin panelida **"Connect buttons" bosilmasin**. Agar bosilsa, webhook
> Winter'dan olinib qoladi va Winter tugmalari ishlamay qoladi. Prompt bu tugmani
> `TELEGRAM_SHARED=true` bo'lganda yashiradi. Agar shunday bo'lib qolsa, Winter admin panelida
> **Pro requests → Connect buttons** ni bosing, webhook Winter'ga qaytadi.
