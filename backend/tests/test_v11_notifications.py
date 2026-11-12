# V11: conversation notification data, inline reply semantics, login
# welcome push, and one push per real booking/payment event.
import json

from app.models.models import Message
from app.routers import notifications as notif_router


def _jobs(env):
    """Every PushJob queued after commit, in order (one submit can carry
    several jobs)."""
    out = []
    for _fn, args in env.push.queued:
        a0 = args[0]
        out.extend(a0 if isinstance(a0, list) else [a0])
    return out


def _send(env, a, b, text):
    r = env.client.post(f"/api/chats/{b['id']}", json={"body": text},
                        headers=env.auth(a))
    assert r.status_code == 201, r.text
    return r.json()["message"]


def _msg(env, mid):
    db = env.db_factory()
    try:
        return db.get(Message, mid)
    finally:
        db.close()


# ── conversation grouping ───────────────────────────────────────────────
def test_chat_push_carries_recent_unread_lines_oldest_first(env):
    a, b = env.make_user("Asha"), env.make_user("Bala")
    for t in ("one", "two", "three"):
        _send(env, a, b, t)
    data = _jobs(env)[-1].data
    lines = json.loads(data["recent"])
    assert [l["t"] for l in lines] == ["one", "two", "three"]
    assert all(l["ts"] for l in lines)
    assert data["conversation_tag"] == f"gms-chat-{a['id']}"
    # B opens the chat (read) → the next notification starts fresh
    env.client.get(f"/api/chats/{a['id']}", headers=env.auth(b))
    _send(env, a, b, "four")
    assert [l["t"] for l in json.loads(_jobs(env)[-1].data["recent"])] == ["four"]


def test_recent_lines_are_per_conversation_and_bounded(env):
    a, b, c = env.make_user("Asha"), env.make_user("Bala"), env.make_user("Chitra")
    for i in range(8):
        _send(env, a, b, f"a{i} " + "x" * 300)
    _send(env, c, b, "from chitra")
    lines_a = json.loads([j for j in _jobs(env) if j.data["partner_id"] == str(a["id"])][-1].data["recent"])
    assert len(lines_a) == 5 and lines_a[-1]["t"].startswith("a7")
    assert all(len(l["t"]) <= 120 for l in lines_a)
    lines_c = json.loads(_jobs(env)[-1].data["recent"])
    assert [l["t"] for l in lines_c] == ["from chitra"]
    total = sum(len(k) + len(v.encode()) for k, v in _jobs(env)[-1].data.items())
    assert total < 4000                       # FCM data payload limit is 4 KB


# ── sending a message never marks the incoming one read ─────────────────
def test_sending_a_message_does_not_mark_incoming_read(env):
    a, b = env.make_user("Asha"), env.make_user("Bala")
    incoming = _send(env, a, b, "are you free?")
    # The device acknowledged it (two grey ticks) …
    env.client.post("/api/chats/receipts/delivered",
                    json={"message_ids": [incoming["id"]]}, headers=env.auth(b))
    # … and B sends a message back without opening the thread (POST only).
    r = env.client.post(f"/api/chats/{a['id']}", json={"body": "yes, 5pm"},
                        headers={**env.auth(b), "Idempotency-Key": "reply-key-0001-abc"})
    assert r.status_code == 201
    m = _msg(env, incoming["id"])
    assert m.delivered_at is not None          # grey ticks still work
    assert m.is_read is False and m.read_at is None   # NO blue ticks
    reply = _msg(env, r.json()["message"]["id"])
    assert reply.sender_id == b["id"] and reply.body == "yes, 5pm"


# ── login welcome: one device only ──────────────────────────────────────
def test_welcome_goes_only_to_the_signed_in_device_once(env):
    notif_router._recent_welcomes.clear()
    u = env.make_user("Una")
    env.register(u, "tok-phone", "android", "device-phone-0001")
    env.register(u, "tok-laptop", "web", "device-laptop-0001")
    env.push.mode = "inline"
    h = env.auth(u)
    r = env.client.post("/api/notifications/welcome",
                        json={"device_id": "device-phone-0001"}, headers=h)
    assert r.json() == {"success": True, "sent": True}
    sent_to = [m.token for m in env.fcm.calls]
    assert sent_to == ["tok-phone"]                       # not the laptop
    assert env.fcm.calls[0].notification.title == "Welcome back to GMS"
    r = env.client.post("/api/notifications/welcome",
                        json={"device_id": "device-phone-0001"}, headers=h)
    assert r.json()["sent"] is False and len(env.fcm.calls) == 1   # retry: no repeat
    # no history row for the welcome
    assert env.client.get("/api/notifications/unread-count", headers=h).json().get("count", 0) == 0


def test_welcome_needs_a_registered_token_and_a_session(env):
    notif_router._recent_welcomes.clear()
    u, other = env.make_user("Una"), env.make_user("Oli")
    env.register(other, "tok-other", "android", "device-other-0001")
    r = env.client.post("/api/notifications/welcome",
                        json={"device_id": "device-other-0001"}, headers=env.auth(u))
    assert r.json()["sent"] is False and r.json()["reason"] == "no_active_token"
    assert env.client.post("/api/notifications/welcome", json={"device_id": "x"}).status_code == 401
    assert env.client.post("/api/notifications/welcome", json={},
                           headers=env.auth(u)).status_code == 400


# ── booking / payment events: one push, right person, no retry duplicates ──
def _act(env, user, bid, action, **extra):
    return env.client.put(f"/api/bookings/{bid}/action", json={"action": action, **extra},
                          headers=env.auth(user))


def test_each_booking_event_pushes_once_to_the_right_person(env):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(prov)
    before = env.push.submit_count
    r = env.client.post("/api/bookings", json={"service_id": svc}, headers=env.auth(cust))
    bid = r.json()["booking"]["id"]
    assert env.push.submit_count == before + 1 and _jobs(env)[-1].user_id == prov["id"]
    assert "Booking" in _jobs(env)[-1].title                       # request received

    n = env.push.submit_count
    assert _act(env, prov, bid, "accept").status_code == 200       # accepted
    assert env.push.submit_count == n + 1 and _jobs(env)[-1].user_id == cust["id"]
    assert _act(env, prov, bid, "accept").status_code == 400       # retry/double tap
    assert env.push.submit_count == n + 1                          # no duplicate

    n = env.push.submit_count
    assert _act(env, cust, bid, "pay_advance").status_code == 200  # paid → confirmed
    assert env.push.submit_count == n + 1 and _jobs(env)[-1].user_id == prov["id"]
    assert "confirmed" in _jobs(env)[-1].title.lower()
    assert _act(env, cust, bid, "pay_advance").status_code == 400
    assert env.push.submit_count == n + 1


def test_reject_pushes_once_to_the_customer(env):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(prov)
    bid = env.client.post("/api/bookings", json={"service_id": svc},
                          headers=env.auth(cust)).json()["booking"]["id"]
    n = env.push.submit_count
    assert _act(env, prov, bid, "reject", reason="Fully booked").status_code == 200
    assert env.push.submit_count == n + 1 and _jobs(env)[-1].user_id == cust["id"]
    assert _act(env, prov, bid, "reject", reason="again").status_code == 400
    assert env.push.submit_count == n + 1
