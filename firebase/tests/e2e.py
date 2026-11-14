#!/usr/bin/env python3
"""End-to-end test of the Winter Firebase backend against the emulators.

  firebase emulators:start --only auth,firestore,functions --project demo-winter
  python3 firebase/tests/e2e.py

Starts a fake Telegram Bot API on 127.0.0.1:8765 and expects the functions to
use it (firebase/functions/.env.local: TELEGRAM_API=http://127.0.0.1:8765,
TELEGRAM_CHAT_ID=1000; .secret.local: TELEGRAM_BOT_TOKEN=<anything>,
TELEGRAM_WEBHOOK_SECRET=local-telegram-secret).
"""
import datetime
import http.server
import threading
import json
import os
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request

PROJECT = "demo-winter"
AUTH = os.environ.get("AUTH_EMULATOR", "http://127.0.0.1:9099")
FS = os.environ.get("FIRESTORE_EMULATOR", "http://127.0.0.1:8080")
FN = os.environ.get("FUNCTIONS_URL", f"http://127.0.0.1:5001/{PROJECT}/europe-west1")
TG_SECRET = "local-telegram-secret"
TG_PORT = 8765
CHAT = 1000
DOCS = f"{FS}/v1/projects/{PROJECT}/databases/(default)/documents"


def req(method, url, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(r, timeout=60) as res:
            text = res.read().decode()
            return res.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        try:
            return e.code, json.loads(text)
        except ValueError:
            return e.code, text


def app(path, body=None, token=None):
    return req("POST", f"{FN}/app{path}", body or {}, {"Authorization": f"Bearer {token}"} if token else {})


class FakeTelegram(http.server.BaseHTTPRequestHandler):
    """Records Bot API calls; answers like Telegram does."""
    calls = []
    next_id = [100]

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        method = self.path.rsplit("/", 1)[-1]
        FakeTelegram.calls.append((method, body))
        if method == "sendMessage":
            FakeTelegram.next_id[0] += 1
            result = {"message_id": FakeTelegram.next_id[0], "chat": {"id": int(body["chat_id"])}, "text": body["text"]}
        elif method == "getMe":
            result = {"id": 1, "is_bot": True, "first_name": "Winter test", "username": "winter_test_bot"}
        elif method == "getWebhookInfo":
            result = {"url": "", "pending_update_count": 0}
        else:
            result = True
        out = json.dumps({"ok": True, "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def tg_calls(method):
    return [b for m, b in FakeTelegram.calls if m == method]


def bot_press(msg_id, data, username="boss", chat=CHAT, secret=TG_SECRET):
    """What Telegram posts to telegramWebhook when an inline button is pressed."""
    upd = {"update_id": 1, "callback_query": {"id": f"cb{msg_id}{data}", "from": {"id": 7, "username": username},
                                              "message": {"message_id": msg_id, "chat": {"id": chat}}, "data": data}}
    return req("POST", f"{FN}/telegramWebhook", upd, {"X-Telegram-Bot-Api-Secret-Token": secret})


def wait_for(fn, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.3)
    return fn()


def google_sign_in(email):
    """What 'Sign in with Google' does, via the Auth emulator's fake IdP."""
    claims = json.dumps({"sub": "g-" + email, "email": email, "email_verified": True, "name": email.split("@")[0]})
    body = {"postBody": f"id_token={urllib.parse.quote(claims)}&providerId=google.com",
            "requestUri": "http://localhost", "returnSecureToken": True, "returnIdpCredential": True}
    c, r = req("POST", f"{AUTH}/identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=fake", body)
    assert c == 200, (c, r)
    return r["idToken"], r["localId"]


def email_link_sign_in(email):
    """What the email-link flow does: send link, read it from the emulator, complete."""
    c, r = req("POST", f"{AUTH}/identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=fake",
               {"requestType": "EMAIL_SIGNIN", "email": email, "continueUrl": "http://localhost:5173/account", "canHandleCodeInApp": True})
    assert c == 200, (c, r)
    _, codes = req("GET", f"{AUTH}/emulator/v1/projects/{PROJECT}/oobCodes")
    code = [x for x in codes["oobCodes"] if x["email"] == email and x["requestType"] == "EMAIL_SIGNIN"][-1]["oobCode"]
    c, r = req("POST", f"{AUTH}/identitytoolkit.googleapis.com/v1/accounts:signInWithEmailLink?key=fake", {"email": email, "oobCode": code})
    assert c == 200, (c, r)
    return r["idToken"], r["localId"]


def unverified_sign_up(email):
    c, r = req("POST", f"{AUTH}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake",
               {"email": email, "password": "secret123", "returnSecureToken": True})
    assert c == 200, (c, r)
    return r["idToken"]


def fsval(v):
    if v is None:
        return {"nullValue": None}
    if isinstance(v, bool):
        return {"booleanValue": v}
    if isinstance(v, datetime.datetime):
        return {"timestampValue": v.isoformat().replace("+00:00", "Z")}
    if isinstance(v, (int, float)):
        return {"doubleValue": v}
    return {"stringValue": v}


def fs(method, path, token="owner", fields=None, params=""):
    body = {"fields": {k: fsval(v) for k, v in fields.items()}} if fields is not None else None
    return req(method, f"{DOCS}/{path}{params}", body, {"Authorization": f"Bearer {token}"})


def run_query(collection, token):
    return req("POST", f"{DOCS}:runQuery", {"structuredQuery": {"from": [{"collectionId": collection}]}},
               {"Authorization": f"Bearer {token}"})


now_dt = lambda: datetime.datetime.now(datetime.timezone.utc)
passed = 0


def check(name, cond, detail=""):
    global passed
    if not cond:
        raise AssertionError(f"FAIL {name}: {detail}")
    passed += 1
    print(f"  ok  {name}")


def request_doc(rid, token="owner"):
    c, r = fs("GET", f"proRequests/{rid}", token)
    return {k: list(v.values())[0] for k, v in r.get("fields", {}).items()} if c == 200 else None


def last_edit_of(msg_id):
    edits = [b for b in tg_calls("editMessageText") if b["message_id"] == msg_id]
    return edits[-1] if edits else None


def buttons(markup):
    return [b["callback_data"].rsplit(":", 1)[1] for row in markup["inline_keyboard"] for b in row]


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", TG_PORT), FakeTelegram)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    run = secrets.token_hex(3)
    user_email = f"user-{run}@example.com"
    other_email = f"other-{run}@example.com"
    admin_email = f"admin-{run}@example.com"
    install_id = secrets.token_hex(24)

    print("anonymous app")
    c, r = app("/heartbeat", {"installId": install_id, "platform": "macos", "appVersion": "1.0.0", "launch": True})
    check("heartbeat", c == 200 and r["ok"], r)
    c, r = app("/heartbeat", {"installId": install_id, "platform": "macos", "launch": True})
    c, r = fs("GET", f"installs/{install_id}")
    check("install recorded, launches counted", r["fields"]["launches"]["integerValue"] == "2", r)
    c, r = app("/heartbeat", {"installId": "short"})
    check("heartbeat rejects bad id", c == 400, r)
    c, r = app("/status", {})
    check("status without token", c == 200 and r["signedIn"] is False and r["pro"] is False, r)

    print("device sign-in")
    code = secrets.token_urlsafe(32)
    c, r = app("/link/start", {"installId": install_id, "code": code, "next": "upgrade"})
    check("link start", c == 200 and code in r["url"] and "next=upgrade" in r["url"], r)
    c, r = app("/link/poll", {"code": code})
    check("poll pending", r["status"] == "pending", r)
    c, r = app("/link/approve", {"code": code})
    check("approve needs session", c == 401, r)
    c, r = app("/link/approve", {"code": code}, unverified_sign_up(f"unverified-{run}@example.com"))
    check("approve needs a verified email", c == 401, r)
    jwt, user_id = email_link_sign_in(user_email)
    c, r = app("/link/approve", {"code": code}, jwt)
    check("approve (email-link user)", c == 200, r)
    c, r = app("/link/approve", {"code": code}, jwt)
    check("approve only once", c == 410, r)
    c, r = app("/link/poll", {"code": code, "installId": install_id, "platform": "macos"})
    check("poll approved -> token", r["status"] == "approved" and len(r["token"]) > 30 and r["email"] == user_email, r)
    token = r["token"]
    c, r = app("/link/poll", {"code": code})
    check("token issued once", r["status"] == "expired", r)
    c, r = app("/status", {"token": token})
    check("signed in, not pro", r["signedIn"] and r["email"] == user_email and not r["pro"] and r["access"] == "none"
          and r["upgradeUrl"].endswith("/upgrade"), r)

    print("new users -> Telegram")
    c, r = app("/hello", {}, jwt)
    check("hello registers the user", c == 200 and r["created"] is True, r)
    c, r = app("/hello", {}, jwt)
    check("hello is idempotent", c == 200 and r["created"] is False, r)
    hellos = [b for b in tg_calls("sendMessage") if user_email in b["text"] and "Yangi foydalanuvchi" in b["text"]]
    check("bot told about the new user exactly once", len(hellos) == 1 and hellos[0]["chat_id"] == str(CHAT), hellos)

    print("security rules (portal clients)")
    c, r = run_query("installs", jwt)
    check("user can't list installs", c == 403, r)
    c, r = fs("POST", "grants", jwt, {"email": user_email, "createdBy": user_email, "revokedAt": None})
    check("user can't grant", c == 403, r)
    c, r = fs("POST", "proRequests", jwt, {"email": user_email, "userId": user_id, "status": "approved"})
    check("user can't write requests directly", c == 403, r)
    c, r = app("/admin/users", {}, jwt)
    check("non-admin can't list users", c == 403, r)
    c, r = app("/admin/stats", {}, jwt)
    check("non-admin can't read stats", c == 403, r)

    print("Pro request validation")
    c, r = app("/pro/request", {"name": "Ali"})
    check("request needs sign-in", c == 401, r)
    c, r = app("/pro/request", {"name": " "}, jwt)
    check("name required", c == 400 and r["error"] == "name", r)
    c, r = app("/pro/request", {"name": "Ali Valiyev", "telegram": "bad name!"}, jwt)
    check("telegram username validated", c == 400 and r["error"] == "telegram", r)
    c, r = app("/pro/request", {"name": "Ali Valiyev", "phone": "call me"}, jwt)
    check("phone validated", c == 400 and r["error"] == "phone", r)

    print("Pro request -> bot -> approve from Telegram")
    sent_before = len(tg_calls("sendMessage"))
    c, r = app("/pro/request", {"name": "Ali Valiyev", "telegram": "@ali_v", "phone": "+998 90 123-45-67",
                                "email": "spoof@example.com"}, jwt)
    check("request created (email from the account, not the body)", c == 200 and r["request"]["status"] == "pending"
          and r["request"]["email"] == user_email and r["request"]["telegram"] == "ali_v", r)
    rid = r["request"]["id"]
    c, r = app("/pro/request", {"name": "Ali Valiyev"}, jwt)
    check("one pending request at a time", c == 409 and r["error"] == "pending", r)
    msgs = tg_calls("sendMessage")[sent_before:]
    check("bot got the request", len(msgs) == 1 and "Pro so'rov" in msgs[0]["text"] and user_email in msgs[0]["text"]
          and "@ali_v" in msgs[0]["text"] and buttons(msgs[0]["reply_markup"]) == ["approve", "reject"], msgs)
    doc = request_doc(rid)
    msg_id = int(doc["telegramMessageId"])
    check("message id stored for edits", msg_id > 100 and doc["telegramChatId"] == str(CHAT), doc)
    c, r = request_doc(rid, jwt), None
    check("user can read own request", c is not None and c["status"] == "pending", c)
    c, r = app("/account", {}, jwt)
    check("account shows pending request", c == 200 and r["request"]["status"] == "pending" and not r["pro"], r)

    c, r = bot_press(msg_id, f"req:{rid}:approve", secret="wrong")
    check("webhook rejects a bad secret", c == 401, r)
    c, r = bot_press(msg_id, f"req:{rid}:approve", chat=999)
    check("presses from another chat are ignored", c == 200 and request_doc(rid)["status"] == "pending", r)
    c, r = bot_press(msg_id, f"req:{rid}:approve")
    check("approve in Telegram", c == 200 and request_doc(rid)["status"] == "approved"
          and request_doc(rid)["decidedBy"] == "telegram:@boss", request_doc(rid))
    c, r = app("/status", {"token": token})
    check("approved -> app gets Pro", r["pro"] and r["access"] == "pro", r)
    e = last_edit_of(msg_id)
    check("bot message re-rendered as approved", e and "Tasdiqlandi" in e["text"] and buttons(e["reply_markup"]) == ["revoke"], e)
    answers = tg_calls("answerCallbackQuery")
    check("button press answered", answers and "Pro berildi" in answers[-1]["text"], answers)
    c, r = bot_press(msg_id, f"req:{rid}:reject")
    check("stale button is a no-op", request_doc(rid)["status"] == "approved"
          and "allaqachon" in tg_calls("answerCallbackQuery")[-1]["text"], tg_calls("answerCallbackQuery")[-1])
    c, r = app("/pro/request", {"name": "Ali Valiyev"}, jwt)
    check("no new request while Pro", c == 409 and r["error"] == "already-pro", r)

    print("admin panel <-> bot sync")
    fs("PATCH", f"admins/{admin_email}", fields={"addedAt": now_dt()})
    ajwt, _ = google_sign_in(admin_email)
    c, r = run_query("proRequests", ajwt)
    check("admin reads requests (live list)", c == 200 and any(rid in x.get("document", {}).get("name", "") for x in r), r)
    c, r = app("/admin/requests/decide", {"id": rid, "action": "revoke"}, jwt)
    check("deciding needs admin", c == 403, r)
    c, r = app("/admin/requests/decide", {"id": rid, "action": "revoke"}, ajwt)
    check("revoke in the panel", c == 200 and r["changed"] and request_doc(rid)["status"] == "revoked", r)
    e = last_edit_of(msg_id)
    check("bot message shows the panel's revoke", "Pro bekor qilindi" in e["text"] and admin_email in e["text"]
          and buttons(e["reply_markup"]) == ["approve"], e)
    c, r = app("/status", {"token": token})
    check("revoked -> no Pro", not r["pro"], r)
    c, r = app("/admin/requests/decide", {"id": rid, "action": "approve"}, ajwt)
    check("re-approve in the panel", r["status"] == "approved", r)
    check("bot shows approved again", "Tasdiqlandi" in last_edit_of(msg_id)["text"], last_edit_of(msg_id))
    c, r = app("/admin/requests/decide", {"id": "nope", "action": "approve"}, ajwt)
    check("unknown request -> 404", c == 404, r)
    c, r = app("/admin/requests/decide", {"id": rid, "action": "delete"}, ajwt)
    check("unknown action -> 400", c == 400, r)

    print("grant revoked in the Free access tab -> request + bot")
    grant_id = request_doc(rid)["grantId"]
    edits_before = len(tg_calls("editMessageText"))
    c, r = fs("PATCH", f"grants/{grant_id}", ajwt, {"revokedAt": now_dt(), "revokedBy": admin_email},
              "?updateMask.fieldPaths=revokedAt&updateMask.fieldPaths=revokedBy")
    check("admin revokes the grant directly", c == 200, r)
    check("trigger marks the request revoked", wait_for(lambda: request_doc(rid)["status"] == "revoked"), request_doc(rid))
    check("trigger updates the bot message", wait_for(lambda: len(tg_calls("editMessageText")) > edits_before
                                                       and "Pro bekor qilindi" in last_edit_of(msg_id)["text"]), last_edit_of(msg_id))
    c, r = fs("PATCH", f"grants/{grant_id}", ajwt, {"revokedBy": "someone@example.com"}, "?updateMask.fieldPaths=revokedBy")
    check("revokedBy must be the real admin", c == 403, r)

    print("reject")
    ojwt, _ = google_sign_in(other_email)
    app("/hello", {}, ojwt)
    c, r = app("/pro/request", {"name": "Vali"}, ojwt)
    check("second user's request (contacts optional)", c == 200 and r["request"]["telegram"] is None, r)
    rid2 = r["request"]["id"]
    m2 = int(request_doc(rid2)["telegramMessageId"])
    c, r = app("/admin/requests/decide", {"id": rid2, "action": "reject"}, ajwt)
    check("reject in the panel", request_doc(rid2)["status"] == "rejected" and "Rad etildi" in last_edit_of(m2)["text"], r)
    c, r = request_doc(rid2, jwt), None
    check("users can't read others' requests", c is None, c)
    c, r = app("/pro/request", {"name": "Vali"}, ojwt)
    check("may ask again after a rejection", c == 200, r)

    print("free access by email (no request)")
    c, r = fs("POST", "grants", ajwt, {"email": other_email, "note": "friend", "createdBy": admin_email,
                                       "createdAt": now_dt(), "revokedAt": None, "expiresAt": None})
    check("admin gives Pro directly", c == 200, r)
    c, r = fs("POST", "grants", ajwt, {"email": user_email, "createdBy": "someone-else@example.com", "revokedAt": None})
    check("grant must record the real admin", c == 403, r)
    c, r = fs("POST", "grants", ajwt, {"email": user_email, "createdBy": admin_email, "revokedAt": None, "requestId": rid})
    check("panel can't fake a request grant", c == 403, r)
    c, r = app("/account", {}, ojwt)
    check("direct grant -> pro", r["pro"] and r["grantNote"] == "friend", r)
    fs("POST", "grants", ajwt, {"email": user_email, "createdBy": admin_email, "revokedAt": None,
                                "expiresAt": datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)})
    c, r = app("/status", {"token": token})
    check("expired grant -> not pro", not r["pro"], r)

    print("bootstrap admin (ADMIN_EMAILS)")
    bjwt, _ = google_sign_in("boot-admin@example.com")
    app("/hello", {}, bjwt)
    c, r = app("/admin/stats", {}, bjwt)
    check("ADMIN_EMAILS address becomes admin on first sign-in", c == 200, r)

    print("admin read models + Telegram status")
    c, r = app("/admin/users", {}, ajwt)
    u = [x for x in r["users"] if x["email"] == user_email][0]
    check("users row has contact + request", u["name"] == "Ali Valiyev" and u["telegram"] == "ali_v"
          and u["request_status"] == "revoked" and u["access"] == "none" and u["installs"] == 1, u)
    o = [x for x in r["users"] if x["email"] == other_email][0]
    check("users row shows Pro", o["access"] == "pro" and o["request_status"] == "pending", o)
    c, r = app("/admin/stats", {}, ajwt)
    check("stats", c == 200 and r["users"] >= 3 and r["pro"] >= 1 and r["pending"] >= 1 and r["revoked"] >= 1
          and r["rejected"] >= 1 and len(r["new_installs_14d"]) == 14, r)
    c, r = app("/admin/telegram/status", {}, ajwt)
    check("telegram status", c == 200 and r["configured"] and r["bot"]["username"] == "winter_test_bot"
          and r["expectedUrl"].endswith("/telegramWebhook"), r)
    c, r = app("/admin/telegram/connect", {}, ajwt)
    hook = tg_calls("setWebhook")[-1]
    check("connect sets the webhook with the secret", c == 200 and hook["secret_token"] == TG_SECRET
          and "callback_query" in hook["allowed_updates"], (r, hook))
    c, r = req("POST", f"{FN}/telegramWebhook", {"update_id": 2, "message": {"chat": {"id": 42}, "text": "/id"}},
               {"X-Telegram-Bot-Api-Secret-Token": TG_SECRET})
    check("/id replies with the chat id", c == 200 and "42" in tg_calls("sendMessage")[-1]["text"], tg_calls("sendMessage")[-1])
    c, r = run_query("installs", ajwt)
    check("admin can list installs", c == 200 and len(r) >= 1, r)

    print("sign out")
    app("/signout", {"token": token})
    c, r = app("/status", {"token": token})
    check("revoked token -> signed out", r["signedIn"] is False, r)

    server.shutdown()
    print(f"\nall {passed} checks passed")
