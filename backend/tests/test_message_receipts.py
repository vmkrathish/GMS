# Chat previews, per-conversation notification identity, and
# sent -> delivered -> read receipts (both directions).
from app.models.models import Message
from app.routers.chats import conversation_tag, message_preview
from app.services import notify as notify_mod


def _send(env, a, b, text):
    r = env.client.post(f"/api/chats/{b['id']}", json={"body": text},
                        headers=env.auth(a))
    assert r.status_code == 201, r.text
    return r.json()["message"]


def _thread(env, viewer, partner):
    r = env.client.get(f"/api/chats/{partner['id']}", headers=env.auth(viewer))
    assert r.status_code == 200
    return {m["id"]: m for m in r.json()["messages"]}


def _ack(env, user, ids):
    return env.client.post("/api/chats/receipts/delivered",
                           json={"message_ids": ids}, headers=env.auth(user))


def _db_msg(env, mid):
    db = env.db_factory()
    try:
        return db.get(Message, mid)
    finally:
        db.close()


def test_push_carries_preview_message_id_and_conversation_tag(env):
    a, b = env.make_user("Asha"), env.make_user("Bala")
    env.register(b, "b-and", "android", "device-band-0001")
    m = _send(env, a, b, "Can you come at 6?")
    # Build the Android/Web messages the push worker would send for it.
    job = notify_mod.PushJob(user_id=b["id"], title="Asha", body="Can you come at 6?",
                             data={"screen": "chat", "partner_id": str(a["id"]),
                                   "message_id": str(m["id"]),
                                   "conversation_tag": conversation_tag(a["id"])})
    msg = notify_mod.build_message(notify_mod._Target(1, "tok", "android"), job)
    assert msg.notification.title == "Asha"
    assert msg.notification.body == "Can you come at 6?"
    assert msg.android.notification.tag == f"gms-chat-{a['id']}"
    assert msg.android.notification.visibility == "private"
    assert msg.data["message_id"] == str(m["id"])
    web = notify_mod.build_message(notify_mod._Target(2, "tok", "web"), job)
    assert web.notification is None          # web stays data-only (no duplicates)
    assert web.data["body"] == "Can you come at 6?"


def test_chat_is_not_saved_in_the_in_app_notifications_page(env):
    # V16: chat alerts are push-only; the page shows business events only.
    a, b = env.make_user("Asha"), env.make_user("Bala")
    _send(env, a, b, "hello   there\nfriend")
    r = env.client.get("/api/notifications", headers=env.auth(b)).json()
    items = r.get("notifications") or r.get("items") or []
    assert items == []
    assert env.client.get("/api/notifications/unread-count",
                          headers=env.auth(b)).json()["unread"] == 0


def test_preview_is_trimmed():
    long = "x" * 500
    p = message_preview(long)
    assert len(p) == 160 and p.endswith("…")
    assert message_preview("  a\n b ") == "a b"


def test_sent_then_delivered_then_read_in_both_directions(env):
    a, b = env.make_user("Asha"), env.make_user("Bala")
    for sender, rcpt in ((a, b), (b, a)):
        m = _send(env, sender, rcpt, f"from {sender['name']}")
        # SENT: saved, not delivered, not read
        assert m["delivered_at"] is None and m["is_read"] == 0
        assert _db_msg(env, m["id"]).delivered_at is None
        # DELIVERED: only the recipient's device ack counts
        assert _ack(env, rcpt, [m["id"]]).json()["updated"] == 1
        seen_by_sender = _thread(env, sender, rcpt)[m["id"]]
        assert seen_by_sender["delivered_at"] and not seen_by_sender["is_read"]
        # retry of the same ack: no change, no error
        first = _db_msg(env, m["id"]).delivered_at
        assert _ack(env, rcpt, [m["id"]]).json()["updated"] == 0
        assert _db_msg(env, m["id"]).delivered_at == first
        # READ: recipient opens the conversation
        _thread(env, rcpt, sender)
        seen_by_sender = _thread(env, sender, rcpt)[m["id"]]
        assert seen_by_sender["is_read"] and seen_by_sender["read_at"]


def test_ack_is_recipient_scoped_and_validated(env):
    a, b, c = env.make_user("Asha"), env.make_user("Bala"), env.make_user("Chitra")
    m = _send(env, a, b, "private")
    assert _ack(env, a, [m["id"]]).json()["updated"] == 0      # the sender
    assert _ack(env, c, [m["id"]]).json()["updated"] == 0      # a stranger
    assert _db_msg(env, m["id"]).delivered_at is None
    assert env.client.post("/api/chats/receipts/delivered",
                           json={"message_ids": [m["id"]]}).status_code == 401
    for bad in ({}, {"message_ids": []}, {"message_ids": "1"},
                {"message_ids": ["x"]}, {"message_ids": list(range(101))}):
        assert _ack_raw(env, b, bad).status_code == 400, bad


def _ack_raw(env, user, payload):
    return env.client.post("/api/chats/receipts/delivered", json=payload,
                           headers=env.auth(user))


def test_offline_recipient_gets_delivered_when_app_next_syncs(env):
    # No device ack ever arrived (phone off / app force-stopped). The next
    # time the recipient's app loads the conversation list, it's delivered.
    a, b = env.make_user("Asha"), env.make_user("Bala")
    m = _send(env, a, b, "while you were away")
    assert _db_msg(env, m["id"]).delivered_at is None
    env.client.get("/api/chats", headers=env.auth(b))
    assert _db_msg(env, m["id"]).delivered_at is not None
    assert not _db_msg(env, m["id"]).is_read
