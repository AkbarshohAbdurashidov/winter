#!/usr/bin/env python3
"""End-to-end test of the Winter backend against a local Supabase stack.

  cd backend && supabase start && supabase functions serve --env-file <env>
  python3 tests/e2e.py

<env> must contain REVENUECAT_WEBHOOK_AUTH=local-webhook-secret and no
REVENUECAT_SECRET_KEY (RevenueCat itself isn't called locally).
"""
import json
import os
import re
import secrets
import subprocess
import time
import urllib.error
import urllib.request

API = os.environ.get("SUPABASE_URL", "http://127.0.0.1:54321")
MAIL = os.environ.get("MAILPIT_URL", "http://127.0.0.1:54324")
WEBHOOK_SECRET = "local-webhook-secret"


def status_env():
    out = subprocess.run(["supabase", "status", "-o", "json"], capture_output=True, text=True,
                         cwd=os.path.join(os.path.dirname(__file__), "..")).stdout
    return json.loads(out[out.index("{"):])


KEYS = status_env()
ANON = KEYS["ANON_KEY"]


def req(method, url, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers={
        "Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(r, timeout=30) as res:
            text = res.read().decode()
            return res.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        try:
            return e.code, json.loads(text)
        except ValueError:
            return e.code, text


def app(path, body=None, jwt=None):
    h = {"apikey": ANON}
    if jwt:
        h["Authorization"] = f"Bearer {jwt}"
    return req("POST", f"{API}/functions/v1/app{path}", body or {}, h)


def rest(method, path, jwt, body=None, prefer=None):
    h = {"apikey": ANON, "Authorization": f"Bearer {jwt}"}
    if prefer:
        h["Prefer"] = prefer
    return req(method, f"{API}/rest/v1/{path}", body, h)


def webhook(event, auth=WEBHOOK_SECRET):
    return req("POST", f"{API}/functions/v1/revenuecat-webhook",
               {"api_version": "1.0", "event": event}, {"Authorization": auth})


def sign_in(email):
    """Email OTP sign-in; reads the code from the local Mailpit inbox."""
    code, _ = req("POST", f"{API}/auth/v1/otp", {"email": email, "create_user": True}, {"apikey": ANON})
    assert code == 200, code
    for _ in range(30):
        _, msgs = req("GET", f"{MAIL}/api/v1/search?query=to:{email}")
        if msgs and msgs.get("messages"):
            mid = msgs["messages"][0]["ID"]
            _, msg = req("GET", f"{MAIL}/api/v1/message/{mid}")
            otp = re.search(r"\b(\d{6})\b", msg["Text"]).group(1)
            code, sess = req("POST", f"{API}/auth/v1/verify",
                             {"email": email, "token": otp, "type": "email"}, {"apikey": ANON})
            assert code == 200, (code, sess)
            return sess["access_token"], sess["user"]["id"]
        time.sleep(0.5)
    raise AssertionError("no OTP email")


def psql(sql):
    subprocess.run(["docker", "exec", "-i", "supabase_db_winter", "psql", "-U", "postgres", "-qc", sql],
                   check=True, capture_output=True)


passed = 0


def check(name, cond, detail=""):
    global passed
    if not cond:
        raise AssertionError(f"FAIL {name}: {detail}")
    passed += 1
    print(f"  ok  {name}")


run = secrets.token_hex(3)
user_email = f"user-{run}@example.com"
admin_email = f"admin-{run}@example.com"
install_id = secrets.token_hex(24)

print("anonymous app")
c, r = app("/heartbeat", {"installId": install_id, "platform": "macos", "appVersion": "1.0.0", "launch": True})
check("heartbeat", c == 200 and r["ok"], r)
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
jwt, user_id = sign_in(user_email)
c, r = app("/link/approve", {"code": code}, jwt)
check("approve", c == 200, r)
c, r = app("/link/approve", {"code": code}, jwt)
check("approve only once", c == 410, r)
c, r = app("/link/poll", {"code": code, "installId": install_id, "platform": "macos"})
check("poll approved -> token", r["status"] == "approved" and len(r["token"]) > 30 and r["email"] == user_email, r)
token = r["token"]
c, r = app("/link/poll", {"code": code})
check("token issued once", r["status"] == "expired", r)
c, r = app("/status", {"token": token})
check("signed in, not pro", r["signedIn"] and r["email"] == user_email and not r["pro"] and r["access"] == "none", r)
c, r = app("/heartbeat", {"installId": install_id, "platform": "macos", "token": token})
check("heartbeat with token", c == 200, r)

print("permissions")
c, r = rest("GET", "admin_users?select=email", jwt)
check("non-admin sees no users", c == 200 and r == [], r)
c, r = rest("POST", "rpc/admin_stats", jwt, {})
check("non-admin stats refused", c in (401, 403), r)
c, r = rest("POST", "grants", jwt, {"email": user_email})
check("non-admin can't grant", c in (401, 403), r)
c, r = rest("GET", "installs?select=install_id", jwt)
check("non-admin can't list installs", r == [], r)

print("admin + free access")
psql(f"insert into public.admins(email) values ('{admin_email}')")
ajwt, _ = sign_in(admin_email)
c, r = rest("POST", "grants", ajwt, {"email": user_email, "note": "beta tester"}, "return=representation")
check("admin grants free pro", c == 201, r)
c, r = app("/status", {"token": token})
check("free access -> pro", r["pro"] and r["access"] == "free", r)
c, r = rest("GET", f"admin_users?email=eq.{user_email}", ajwt)
check("admin_users shows free", r[0]["access"] == "free" and r[0]["installs"] == 1 and r[0]["platforms"] == "macos", r)
c, r = rest("PATCH", f"grants?email=eq.{user_email}", ajwt, {"revoked_at": "2026-01-01T00:00:00Z"})
check("revoke grant", c in (200, 204), r)
c, r = app("/status", {"token": token})
check("revoked -> not pro", not r["pro"], r)
c, r = rest("POST", "grants", ajwt, {"email": user_email, "expires_at": "2020-01-01T00:00:00Z"})
c, r = app("/status", {"token": token})
check("expired grant -> not pro", not r["pro"], r)

print("RevenueCat webhook")
now = int(time.time() * 1000)
day = 86400000
ev = {"id": f"evt-{run}-1", "type": "INITIAL_PURCHASE", "app_user_id": user_id, "original_app_user_id": user_id,
      "aliases": [user_id], "product_id": "yearly", "entitlement_ids": ["winter_pro"], "period_type": "TRIAL",
      "purchased_at_ms": now, "expiration_at_ms": now + 7 * day, "environment": "SANDBOX", "store": "RC_BILLING",
      "price": 0}
c, r = webhook(ev, "wrong")
check("webhook rejects bad auth", c == 401, r)
c, r = webhook(ev)
check("trial purchase", c == 200 and r["ok"], r)
c, r = webhook(ev)
check("duplicate event ignored", r.get("duplicate") is True, r)
c, r = app("/status", {"token": token})
check("trial -> pro", r["pro"] and r["access"] == "trial" and r["productId"] == "yearly", r)
c, r = webhook({**ev, "id": f"evt-{run}-2", "type": "RENEWAL", "period_type": "NORMAL", "is_trial_conversion": True,
                "purchased_at_ms": now + 7 * day, "expiration_at_ms": now + 372 * day, "price": 29.99})
c, r = app("/status", {"token": token})
check("trial converted -> active", r["pro"] and r["access"] == "active", r)
c, r = webhook({**ev, "id": f"evt-{run}-3", "type": "CANCELLATION", "period_type": "NORMAL", "cancel_reason": "UNSUBSCRIBE"})
c, r = app("/status", {"token": token})
check("cancelled keeps access until period end", r["pro"] and r["access"] == "active", r)
c, r = rest("GET", f"admin_users?email=eq.{user_email}", ajwt)
u = r[0]
check("admin sees conversion + revenue", u["had_trial"] and u["converted_from_trial"] and float(u["revenue_usd"]) == 29.99
      and u["will_renew"] is False, u)
c, r = webhook({**ev, "id": f"evt-{run}-4", "type": "EXPIRATION", "period_type": "NORMAL", "expiration_at_ms": now})
c, r = app("/status", {"token": token})
check("expired -> not pro", not r["pro"] and r["access"] == "expired", r)
c, r = webhook({**ev, "id": f"evt-{run}-5", "type": "NON_RENEWING_PURCHASE", "product_id": "lifetime",
                "period_type": "NORMAL", "expiration_at_ms": None, "price": 49.99})
c, r = app("/status", {"token": token})
check("lifetime -> pro", r["pro"] and r["access"] == "lifetime", r)
c, r = webhook({**ev, "id": f"evt-{run}-6", "app_user_id": "$RCAnonymousID:abc", "original_app_user_id": "$RCAnonymousID:abc", "aliases": []})
check("anonymous RevenueCat id ignored", r.get("ignored") is True, r)
c, r = webhook({**ev, "id": f"evt-{run}-7", "entitlement_ids": ["other"]})
check("other entitlement ignored", r.get("ignored") is True, r)

print("admin read models")
c, r = rest("POST", "rpc/admin_stats", ajwt, {})
check("stats", c == 200 and r["installs"] >= 1 and r["lifetime"] >= 1 and r["users"] >= 2
      and float(r["revenue_usd"]) >= 79.98 and len(r["new_installs_14d"]) == 14, r)
c, r = app("/account", {}, jwt)
check("portal account", r["pro"] and r["access"] == "lifetime" and len(r["devices"]) == 1 and r["isAdmin"] is False, r)
c, r = app("/admin/refresh", {"userId": user_id}, jwt)
check("admin refresh needs admin", c == 403, r)
c, r = app("/admin/refresh", {"userId": user_id}, ajwt)
check("admin refresh (RevenueCat not configured locally)", c == 200 and r["configured"] is False, r)

print("sign out")
c, r = app("/signout", {"token": token})
c, r = app("/status", {"token": token})
check("revoked token -> signed out", r["signedIn"] is False, r)

print(f"\nall {passed} checks passed")
