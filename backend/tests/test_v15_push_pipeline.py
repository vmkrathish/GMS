# V15 regression guard: after the notification Reply feature was removed
# (V14) every real event must still reach FCM — for each of the user's
# active devices (Android + Web), once, with the right shape — and only
# after the database commit. Uses the fake FCM sender (no network).
import json
from datetime import datetime, timedelta

from app.routers import notifications as notif_router


def _future(days=3):
    return (datetime.now() + timedelta(days=days)).replace(microsecond=0).isoformat()


def _act(env, user, bid, action, **extra):
    r = env.client.put(f"/api/bookings/{bid}/action",
                       json={"action": action, **extra}, headers=env.auth(user))
    assert r.status_code == 200, (action, r.text)
    return r


def _book(env, cust, svc):
    r = env.client.post("/api/bookings", json={"service_id": svc}, headers=env.auth(cust))
    assert r.status_code in (200, 201), r.text
    return r.json()["booking"]["id"]


def _setup(env):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    env.register(prov, "tok-prov-android", "android", "dev-prov-phone-01")
    env.register(prov, "tok-prov-web", "web", "dev-prov-browser-01")
    env.register(cust, "tok-cust-android", "android", "dev-cust-phone-01")
    env.push.mode = "inline"
    return prov, cust, env.make_service(prov)


def _sent_since(env, n):
    return env.fcm.calls[n:]


def _assert_delivered(msgs, tokens, title_part):
    assert sorted(m.token for m in msgs) == sorted(tokens), [m.token for m in msgs]
    for m in msgs:
        title = m.notification.title if m.notification else m.data["title"]
        assert title_part.lower() in title.lower(), title
        if m.android is not None:                       # Android
            assert m.android.priority == "high"
            assert m.android.notification.channel_id == "gms_default_channel"
            assert m.android.notification.tag             # one slot per chat/event
            assert m.android.notification.visibility == "private"
        else:                                            # Web: data-only, SW shows it once
            assert m.notification is None
            assert m.webpush.headers.get("Urgency") == "high"
        assert m.data["recipient_id"] and m.data["notif_id"]


def test_every_booking_event_reaches_every_device_of_the_right_person(env):
    prov, cust, svc = _setup(env)
    P = ["tok-prov-android", "tok-prov-web"]
    C = ["tok-cust-android"]

    n = len(env.fcm.calls); bid = _book(env, cust, svc)
    _assert_delivered(_sent_since(env, n), P, "booking request")

    n = len(env.fcm.calls); _act(env, prov, bid, "reschedule",
                                 proposed_time=_future(), reason="busy")
    _assert_delivered(_sent_since(env, n), C, "provider proposed")

    n = len(env.fcm.calls); _act(env, cust, bid, "accept_proposal")
    _assert_delivered(_sent_since(env, n), P, "customer accepted")

    b6 = _book(env, cust, svc)
    n = len(env.fcm.calls); _act(env, cust, b6, "counter_proposal",
                                 proposed_time=_future(4), reason="later")
    _assert_delivered(_sent_since(env, n), P, "customer suggested")

    n = len(env.fcm.calls); b2 = _book(env, cust, svc)
    n = len(env.fcm.calls); _act(env, prov, b2, "accept")
    _assert_delivered(_sent_since(env, n), C, "advance")

    n = len(env.fcm.calls); _act(env, cust, b2, "pay_advance")
    _assert_delivered(_sent_since(env, n), P, "confirmed")

    b3 = _book(env, cust, svc)
    n = len(env.fcm.calls); _act(env, prov, b3, "reject", reason="full")
    _assert_delivered(_sent_since(env, n), C, "")

    b4 = _book(env, cust, svc)
    n = len(env.fcm.calls); _act(env, cust, b4, "cancel", reason="plans")
    _assert_delivered(_sent_since(env, n), P, "cancelled by the customer")

    b5 = _book(env, cust, svc)
    n = len(env.fcm.calls); _act(env, prov, b5, "cancel", reason="unwell")
    _assert_delivered(_sent_since(env, n), C, "cancelled by the provider")


def test_chat_reaches_every_device_with_grouping_data(env):
    prov, cust, _ = _setup(env)
    n = len(env.fcm.calls)
    r = env.client.post(f"/api/chats/{prov['id']}", json={"body": "hello"},
                        headers=env.auth(cust))
    assert r.status_code == 201
    msgs = _sent_since(env, n)
    _assert_delivered(msgs, ["tok-prov-android", "tok-prov-web"], "Cust")
    for m in msgs:
        assert m.data["type"] == "chat"
        assert m.data["conversation_tag"] == f"gms-chat-{cust['id']}"
        assert json.loads(m.data["recent"])[-1]["t"] == "hello"
        assert "sender_avatar" in m.data and m.data["message_id"]
    # the sender's own devices get nothing
    assert all(m.token != "tok-cust-android" for m in msgs)


def test_login_welcome_still_targets_only_that_device(env):
    notif_router._recent_welcomes.clear()
    prov, _cust, _ = _setup(env)
    n = len(env.fcm.calls)
    r = env.client.post("/api/notifications/welcome",
                        json={"device_id": "dev-prov-phone-01"}, headers=env.auth(prov))
    assert r.json()["sent"] is True
    assert [m.token for m in _sent_since(env, n)] == ["tok-prov-android"]


def test_unseen_endpoint_carries_the_bell_total(env):
    prov, cust, svc = _setup(env)
    _book(env, cust, svc)
    env.client.post(f"/api/chats/{prov['id']}", json={"body": "hi"}, headers=env.auth(cust))
    u = env.client.get("/api/notifications/booking-unseen", headers=env.auth(prov)).json()
    assert u["count"] == 1 and u["unread_total"] == 1   # chat isn't in the bell (V16)
