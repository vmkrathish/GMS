"""Backend <-> Flutter client contract.

Everything here reproduces what the Dart client and a real browser actually
send/receive: CORS preflights, URL-encoded tokens, the Idempotency-Key
format, and the full logout -> login -> account-switch call sequence. The
web chain feeds the payload the BACKEND really builds into the REAL
service-worker file (via Node).
"""
import json
import re
import shutil
import subprocess
import urllib.parse
from pathlib import Path

import pytest

from app.models.models import Message, Notification, PushToken
from app.utils.helpers import public_user

REPO = Path(__file__).resolve().parents[2]
RUNNER = REPO / "frontend" / "test" / "web_sw" / "contract_runner.js"
DEV_A, DEV_B = "ab12cd34ef56ab12cd34ef56ab12cd34", "99887766554433221100aabbccddeeff"

# A realistic FCM registration token: "<id>:APA91b<~140 url-safe chars>"
REAL_TOKEN = "fXk3_lq9R0e:APA91b" + "Hq-_" * 35


# ═════════════ browser (web) CORS ═════════════

ORIGIN = "https://gms-web.example"


@pytest.mark.parametrize("method,path", [
    ("POST", "/api/chats/2"),
    ("POST", "/api/bookings"),
    ("PUT", "/api/bookings/1/action"),
    ("POST", "/api/notifications/push-token"),
    ("DELETE", "/api/notifications/push-token"),
])
def test_cors_preflight_allows_every_header_the_web_client_sends(env, method, path):
    r = env.client.options(path, headers={
        "Origin": ORIGIN,
        "Access-Control-Request-Method": method,
        "Access-Control-Request-Headers": "authorization,content-type,idempotency-key",
    })
    assert r.status_code == 200, r.text
    allowed = r.headers["access-control-allow-headers"].lower()
    assert "idempotency-key" in allowed or allowed.strip() == "*"
    assert method in r.headers["access-control-allow-methods"]
    assert r.headers["access-control-allow-origin"] in ("*", ORIGIN)


# ═════════════ Dart-style requests ═════════════

def test_dart_style_idempotency_key_is_accepted_and_replays(env):
    sender, rcpt = env.make_user("Sam"), env.make_user("Riya")
    key = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"          # DeviceIdentity.randomId(): 32 hex
    assert re.fullmatch(r"[0-9a-f]{32}", key)
    for header_name in ("Idempotency-Key", "idempotency-key"):   # case-insensitive
        h = dict(env.auth(sender), **{header_name: key})
        r = env.client.post(f"/api/chats/{rcpt['id']}", json={"body": "hi"}, headers=h)
        assert r.status_code == 201
    assert env.count(__import__("app.models.models", fromlist=["Message"]).Message) == 1


def test_a_realistic_url_encoded_fcm_token_round_trips(env):
    """Dart sends the token via Uri.encodeQueryComponent (':' -> %3A)."""
    a = env.make_user("A")
    assert env.register(a, REAL_TOKEN, "web", DEV_A).status_code == 200
    q = urllib.parse.urlencode({"token": REAL_TOKEN, "device_id": DEV_A},
                               quote_via=urllib.parse.quote_plus)
    assert "%3A" in q
    r = env.client.delete(f"/api/notifications/push-token?{q}", headers=env.auth(a))
    assert r.status_code == 200 and r.json()["deactivated"] == 1
    assert env.active(a["id"]) == []


def test_login_response_user_has_the_id_the_dart_recipient_guard_compares():
    class U:  # minimal stand-in; public_user only reads attributes
        pass
    from app.models.models import User
    u = User(id=7, phone="9", name="N")
    assert public_user(u)["id"] == 7        # Dart: '${me['id']}' == data['recipient_id']


# ═════════════ the exact Dart client call sequence ═════════════

def test_client_sequence_logout_login_account_switch_and_second_device(env):
    """Mirrors fcm_service.dart + push_registrar.dart call by call."""
    a, b = env.make_user("Alice"), env.make_user("Bob")
    tok_a1, tok_a2, tok_b = "tokA1:APA91b" + "x" * 60, "tokA2:APA91b" + "y" * 60, "tokB:APA91b" + "z" * 60

    # 1. Alice logs in on the phone  -> POST push-token {token, platform, device_id}
    assert env.register(a, tok_a1, "android", DEV_A).status_code == 200
    # 2. Alice ALSO logs in on a browser (second device)
    assert env.register(a, REAL_TOKEN, "web", DEV_B).status_code == 200
    assert len(env.active(a["id"])) == 2

    # 3. Alice logs out on the phone: DELETE ?token&device_id, then FCM deleteToken()
    q = urllib.parse.urlencode({"token": tok_a1, "device_id": DEV_A}, quote_via=urllib.parse.quote_plus)
    assert env.client.delete(f"/api/notifications/push-token?{q}",
                             headers=env.auth(a)).json()["deactivated"] == 1
    assert [d for _t, d in env.active(a["id"])] == [DEV_B]          # browser unaffected

    # 4. Bob logs in on that SAME phone (new FCM token after deleteToken)
    assert env.register(b, tok_b, "android", DEV_A).status_code == 200
    assert env.active(b["id"]) == [(tok_b, DEV_A)]

    # 5. Nothing addressed to Alice may reach the phone; her browser still gets it
    env.push.mode = "inline"
    r = env.client.post(f"/api/chats/{a['id']}", json={"body": "hi alice"}, headers=env.auth(b))
    assert r.status_code == 201
    assert env.fcm.tokens_sent() == [REAL_TOKEN]
    assert tok_a1 not in env.fcm.tokens_sent() and tok_b not in env.fcm.tokens_sent()

    # 6. Bob logs out; Alice logs back in on the phone with a fresh token
    env.client.delete(f"/api/notifications/push-token?device_id={DEV_A}", headers=env.auth(b))
    assert env.register(a, tok_a2, "android", DEV_A).status_code == 200
    assert env.active(b["id"]) == []
    assert sorted(t for t, _d in env.active(a["id"])) == sorted([tok_a2, REAL_TOKEN])

    # 7. Offline logout: Alice never managed to call DELETE, Bob signs in on the phone
    assert env.register(b, "tokB2:APA91b" + "q" * 60, "android", DEV_A).status_code == 200
    assert [t for t, _d in env.active(a["id"])] == [REAL_TOKEN]     # phone token swept anyway
    env.fcm.calls.clear()
    env.client.post(f"/api/chats/{a['id']}", json={"body": "again"}, headers=env.auth(b))
    assert env.fcm.tokens_sent() == [REAL_TOKEN]


# ═════════════ backend payload -> REAL service worker ═════════════

needs_node = pytest.mark.skipif(shutil.which("node") is None or not RUNNER.exists(),
                                reason="node or the SW runner not available")


def _run_sw(tmp_path, data, click=True):
    f = tmp_path / "in.json"
    f.write_text(json.dumps({"payload": {"data": data}, "click": click}))
    out = subprocess.run(["node", str(RUNNER), str(f)], capture_output=True, text=True, timeout=30)
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)


def _web_message_for(env, rcpt):
    """The data-only message the backend really builds for the recipient's browser."""
    assert [m for m in env.fcm.calls if m.token == "web-tok"], "no web push was built"
    m = [m for m in env.fcm.calls if m.token == "web-tok"][0]
    assert m.notification is None
    return dict(m.data)


@needs_node
def test_chat_push_built_by_backend_shows_exactly_one_web_notification_and_routes_the_tap(env, tmp_path):
    sender, rcpt = env.make_user("Sam"), env.make_user("Riya")
    env.register(rcpt, "web-tok", "web", DEV_B)
    env.push.mode = "inline"
    assert env.client.post(f"/api/chats/{rcpt['id']}", json={"body": "hello"},
                           headers=env.auth(sender)).status_code == 201
    data = _web_message_for(env, rcpt)

    res = _run_sw(tmp_path, data)
    assert len(res["shown"]) == 1                                    # EXACTLY once
    n = res["shown"][0]
    # WhatsApp-style (V10): sender as title, the message text as body.
    assert n["title"] == "Sam" and n["opts"]["body"] and "sent you a message" not in n["opts"]["body"]
    db = env.db_factory()
    try:
        # V16: chat alerts are push-only (no in-app Notifications row)
        assert db.query(Notification).filter_by(user_id=rcpt["id"]).count() == 0
        mid = db.query(Message).filter_by(receiver_id=rcpt["id"]).one().id
    finally:
        db.close()
    assert n["opts"]["tag"] == f"gms-n-chat-{mid}"                   # one tag per message

    assert len(res["opened"]) == 1                                   # no tab open -> new window
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(res["opened"][0]).query))
    # What Dart's takeInitialDeepLink() rebuilds from this URL, and what _handleTap needs:
    assert q["gms_screen"] == "chat"
    assert int(q["gms_partner_id"]) == sender["id"]
    assert int(q["gms_recipient_id"]) == rcpt["id"]


@needs_node
def test_booking_push_built_by_backend_routes_to_the_booking(env, tmp_path):
    provider, customer = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(provider)
    env.register(provider, "web-tok", "web", DEV_B)
    env.push.mode = "inline"
    r = env.client.post("/api/bookings", json={"service_id": svc}, headers=env.auth(customer))
    assert r.status_code == 201
    res = _run_sw(tmp_path, _web_message_for(env, provider))
    assert len(res["shown"]) == 1
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(res["opened"][0]).query))
    assert q["gms_screen"] == "booking"
    assert int(q["gms_booking_id"]) == r.json()["booking"]["id"]
    assert int(q["gms_recipient_id"]) == provider["id"]


@needs_node
def test_foreground_web_handler_has_everything_it_needs_in_data(env):
    """Foreground web pushes reach Dart's onMessage data-only: title/body must
    be in `data` (fcm_service.dart falls back to message.data['title'/'body'])."""
    sender, rcpt = env.make_user("Sam"), env.make_user("Riya")
    env.register(rcpt, "web-tok", "web", DEV_B)
    env.push.mode = "inline"
    env.client.post(f"/api/chats/{rcpt['id']}", json={"body": "x"}, headers=env.auth(sender))
    d = _web_message_for(env, rcpt)
    assert d["title"] and d["body"]
    assert d["notif_id"].startswith("chat-") and d["recipient_id"] == str(rcpt["id"])


def test_android_message_still_carries_a_system_tray_notification_and_the_same_routing_data(env):
    sender, rcpt = env.make_user("Sam"), env.make_user("Riya")
    env.register(rcpt, "and-tok", "android", DEV_A)
    env.push.mode = "inline"
    env.client.post(f"/api/chats/{rcpt['id']}", json={"body": "x"}, headers=env.auth(sender))
    m = env.fcm.calls[0]
    assert m.notification.title == "Sam"                      # background/terminated tray (sender)
    assert m.android.notification.channel_id == "gms_default_channel"   # = AndroidManifest meta-data
    assert m.data["screen"] == "chat" and int(m.data["partner_id"]) == sender["id"]
