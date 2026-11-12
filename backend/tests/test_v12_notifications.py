# V12: notification tags/avatars, retry-safe sends without the
# migration, and once-only read for a notification's View action.
import pytest
from sqlalchemy import text

from app.models.models import Message, Notification
from app.services import idempotency as idem
from app.services import notify as notify_mod


def _jobs(env):
    out = []
    for _fn, args in env.push.queued:
        a0 = args[0]
        out.extend(a0 if isinstance(a0, list) else [a0])
    return out


@pytest.fixture()
def no_idempotency_table(env, engine):
    with engine.begin() as c:
        c.execute(text("ALTER TABLE idempotency_keys RENAME TO idempotency_keys_hidden"))
    idem.reset_table_check()
    idem._mem_store.clear()
    try:
        yield
    finally:
        with engine.begin() as c:
            c.execute(text("ALTER TABLE idempotency_keys_hidden RENAME TO idempotency_keys"))
        idem.reset_table_check()
        idem._mem_store.clear()


def _count(env, model, **kw):
    db = env.db_factory()
    try:
        return db.query(model).filter_by(**kw).count()
    finally:
        db.close()


def test_every_android_push_has_a_stable_tag(env):
    job = notify_mod.PushJob(user_id=1, title="New Booking Request", body="b",
                             data={"type": "booking", "screen": "booking",
                                   "booking_id": "9", "notif_id": "77"})
    m = notify_mod.build_message(notify_mod._Target(1, "tok", "android"), job)
    assert m.android.notification.tag == "gms-n-77"      # app's View notification replaces it
    chat = notify_mod.PushJob(user_id=1, title="A", body="b",
                              data={"type": "chat", "notif_id": "78",
                                    "conversation_tag": "gms-chat-5"})
    m = notify_mod.build_message(notify_mod._Target(1, "tok", "android"), chat)
    assert m.android.notification.tag == "gms-chat-5"    # chats keep one slot per person


def test_chat_push_carries_sender_avatar(env):
    a, b = env.make_user("Asha"), env.make_user("Bala")
    db = env.db_factory()
    try:
        from app.models.models import User
        db.get(User, a["id"]).avatar_url = "/static/avatars/a.jpg"
        db.commit()
    finally:
        db.close()
    env.client.post(f"/api/chats/{b['id']}", json={"body": "hi"}, headers=env.auth(a))
    assert _jobs(env)[-1].data["sender_avatar"] == "/static/avatars/a.jpg"
    env.client.post(f"/api/chats/{a['id']}", json={"body": "yo"}, headers=env.auth(b))
    assert _jobs(env)[-1].data["sender_avatar"] == ""     # no photo → app shows the initial


def test_retried_send_with_same_key_saves_once_without_migration(env, no_idempotency_table):
    a, b = env.make_user("Asha"), env.make_user("Bala")
    h = {**env.auth(b), "Idempotency-Key": "nr-msg42-abcdef0123"}
    r1 = env.client.post(f"/api/chats/{a['id']}", json={"body": "on my way"}, headers=h)
    r2 = env.client.post(f"/api/chats/{a['id']}", json={"body": "on my way"}, headers=h)
    assert r1.status_code == r2.status_code == 201
    assert r1.json()["message"]["id"] == r2.json()["message"]["id"]   # replayed
    assert _count(env, Message, sender_id=b["id"]) == 1
    assert len([j for j in _jobs(env) if j.user_id == a["id"]]) == 1  # one push
    # a NEW reply (new key) is a new message
    env.client.post(f"/api/chats/{a['id']}", json={"body": "5 min"},
                    headers={**env.auth(b), "Idempotency-Key": "nr-msg42-ffff000011"})
    assert _count(env, Message, sender_id=b["id"]) == 2


def test_view_marks_that_notification_read_once(env):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(prov)
    env.client.post("/api/bookings", json={"service_id": svc}, headers=env.auth(cust))
    env.client.post("/api/bookings", json={"service_id": svc}, headers=env.auth(cust))
    h = env.auth(prov)
    unread = lambda: env.client.get("/api/notifications/unread-count", headers=h).json()  # noqa: E731
    before = unread()
    key = "count" if "count" in before else "unread"
    assert before[key] == 2
    nid = int(_jobs(env)[-1].data["notif_id"])
    for _ in range(3):                        # View pressed / retried
        assert env.client.put(f"/api/notifications/{nid}/read", json={},
                              headers=h).status_code == 200
    assert unread()[key] == 1                 # only that one, only once
    assert _count(env, Notification, user_id=prov["id"], is_read=False) == 1
