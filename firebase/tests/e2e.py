#!/usr/bin/env python3
"""End-to-end test of the Winter Firebase backend against the emulators.

  firebase emulators:start --only auth,firestore,functions --project demo-winter
  python3 firebase/tests/e2e.py

Uses firebase/functions/.secret.local: REVENUECAT_WEBHOOK_AUTH=local-webhook-secret,
REVENUECAT_SECRET_KEY=unset (RevenueCat itself isn't called).
"""
import datetime
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
WEBHOOK_SECRET = "local-webhook-secret"
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


def webhook(event, auth=WEBHOOK_SECRET):
    return req("POST", f"{FN}/revenuecatWebhook", {"api_version": "1.0", "event": event}, {"Authorization": auth})


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


if __name__ == "__main__":
    run = secrets.token_hex(3)
    user_email = f"user-{run}@example.com"
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
    check("signed in, not pro", r["signedIn"] and r["email"] == user_email and not r["pro"] and r["access"] == "none", r)

    print("security rules (portal clients)")
    c, r = run_query("installs", jwt)
    check("user can't list installs", c == 403, r)
    c, r = fs("POST", "grants", jwt, {"email": user_email, "createdBy": user_email, "revokedAt": None})
    check("user can't grant", c == 403, r)
    c, r = fs("GET", f"subscriptions/{user_id}", jwt)
    check("user may read own subscription", c in (200, 404), r)
    c, r = app("/admin/users", {}, jwt)
    check("non-admin can't list users", c == 403, r)
    c, r = app("/admin/stats", {}, jwt)
    check("non-admin can't read stats", c == 403, r)

    print("admin + free access")
    fs("PATCH", f"admins/{admin_email}", fields={"addedAt": now_dt()})
    ajwt, _ = google_sign_in(admin_email)
    c, r = fs("POST", "grants", ajwt, {"email": user_email, "note": "beta tester", "createdBy": admin_email,
                                       "createdAt": now_dt(), "revokedAt": None, "expiresAt": None})
    check("admin grants free pro (Google user)", c == 200, r)
    grant_name = r["name"].split("/documents/")[1]
    c, r = fs("POST", "grants", ajwt, {"email": user_email, "createdBy": "someone-else@example.com", "revokedAt": None})
    check("grant must record the real admin", c == 403, r)
    c, r = app("/status", {"token": token})
    check("free access -> pro", r["pro"] and r["access"] == "free", r)
    c, r = app("/admin/users", {}, ajwt)
    u = [x for x in r["users"] if x["email"] == user_email][0]
    check("admin users shows free", u["access"] == "free" and u["installs"] == 1 and u["platforms"] == "macos", u)
    c, r = fs("PATCH", grant_name, ajwt, {"revokedAt": now_dt()}, "?updateMask.fieldPaths=revokedAt")
    check("revoke grant", c == 200, r)
    c, r = fs("PATCH", grant_name, ajwt, {"email": "x@example.com"}, "?updateMask.fieldPaths=email")
    check("grant email can't be rewritten", c == 403, r)
    c, r = app("/status", {"token": token})
    check("revoked -> not pro", not r["pro"], r)
    fs("POST", "grants", ajwt, {"email": user_email, "createdBy": admin_email, "revokedAt": None,
                                "expiresAt": datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)})
    c, r = app("/status", {"token": token})
    check("expired grant -> not pro", not r["pro"], r)

    print("RevenueCat webhook")
    now = int(time.time() * 1000)
    day = 86400000
    ev = {"id": f"evt-{run}-1", "type": "INITIAL_PURCHASE", "app_user_id": user_id, "original_app_user_id": user_id,
          "aliases": [user_id], "product_id": "yearly", "entitlement_ids": ["winter_pro"], "period_type": "TRIAL",
          "purchased_at_ms": now, "expiration_at_ms": now + 7 * day, "environment": "SANDBOX", "store": "RC_BILLING", "price": 0}
    c, r = webhook(ev, "wrong")
    check("webhook rejects bad auth", c == 401, r)
    c, r = webhook(ev)
    check("trial purchase", c == 200 and r["ok"], r)
    c, r = webhook(ev)
    check("duplicate event ignored", r.get("duplicate") is True, r)
    c, r = app("/status", {"token": token})
    check("trial -> pro", r["pro"] and r["access"] == "trial" and r["productId"] == "yearly", r)
    webhook({**ev, "id": f"evt-{run}-2", "type": "RENEWAL", "period_type": "NORMAL", "is_trial_conversion": True,
             "purchased_at_ms": now + 7 * day, "expiration_at_ms": now + 372 * day, "price": 29.99})
    c, r = app("/status", {"token": token})
    check("trial converted -> active", r["pro"] and r["access"] == "active", r)
    webhook({**ev, "id": f"evt-{run}-3", "type": "CANCELLATION", "period_type": "NORMAL", "cancel_reason": "UNSUBSCRIBE"})
    c, r = app("/status", {"token": token})
    check("cancelled keeps access until period end", r["pro"] and r["access"] == "active", r)
    c, r = app("/admin/users", {}, ajwt)
    u = [x for x in r["users"] if x["email"] == user_email][0]
    check("admin sees conversion + revenue", u["had_trial"] and u["converted_from_trial"] and u["revenue_usd"] == 29.99
          and u["will_renew"] is False, u)
    webhook({**ev, "id": f"evt-{run}-4", "type": "EXPIRATION", "period_type": "NORMAL", "expiration_at_ms": now})
    c, r = app("/status", {"token": token})
    check("expired -> not pro", not r["pro"] and r["access"] == "expired", r)
    webhook({**ev, "id": f"evt-{run}-5", "type": "NON_RENEWING_PURCHASE", "product_id": "lifetime",
             "period_type": "NORMAL", "expiration_at_ms": None, "price": 49.99})
    c, r = app("/status", {"token": token})
    check("lifetime -> pro", r["pro"] and r["access"] == "lifetime", r)
    c, r = webhook({**ev, "id": f"evt-{run}-6", "app_user_id": "$RCAnonymousID:abc", "original_app_user_id": "$RCAnonymousID:abc", "aliases": []})
    check("anonymous RevenueCat id ignored", r.get("ignored") is True, r)
    c, r = webhook({**ev, "id": f"evt-{run}-7", "entitlement_ids": ["other"]})
    check("other entitlement ignored", r.get("ignored") is True, r)

    print("admin read models")
    c, r = app("/admin/stats", {}, ajwt)
    check("stats", c == 200 and r["installs"] >= 1 and r["lifetime"] >= 1 and r["users"] >= 2
          and r["revenue_usd"] >= 79.98 and len(r["new_installs_14d"]) == 14, r)
    c, r = run_query("installs", ajwt)
    check("admin can list installs", c == 200 and len(r) >= 1, r)
    c, r = app("/account", {}, jwt)
    check("portal account", r["pro"] and r["access"] == "lifetime" and len(r["devices"]) == 1 and r["isAdmin"] is False, r)
    c, r = app("/admin/refresh", {"userId": user_id}, jwt)
    check("admin refresh needs admin", c == 403, r)
    c, r = app("/admin/refresh", {"userId": user_id}, ajwt)
    check("admin refresh (RevenueCat not configured locally)", c == 200 and r["configured"] is False, r)

    print("sign out")
    app("/signout", {"token": token})
    c, r = app("/status", {"token": token})
    check("revoked token -> signed out", r["signedIn"] is False, r)

    print(f"\nall {passed} checks passed")
