# V16: the in-app Notifications page / bell count holds business events
# only (no chat), chat pushes still go out, and FCM calls are time-bounded.
from app.models.models import Notification
from app.services import notify as notify_mod


def _rows(env, user_id):
    db = env.db_factory()
    try:
        return db.query(Notification).filter_by(user_id=user_id).all()
    finally:
        db.close()


def test_chat_pushes_without_a_history_row_and_bookings_still_get_one(env):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    env.register(prov, "tok-prov", "android", "dev-prov-0001")
    env.push.mode = "inline"
    n = len(env.fcm.calls)
    r = env.client.post(f"/api/chats/{prov['id']}", json={"body": "hi"},
                        headers=env.auth(cust))
    msg_id = r.json()["message"]["id"]
    sent = env.fcm.calls[n:]
    assert [m.token for m in sent] == ["tok-prov"]               # push still sent
    assert sent[0].data["notif_id"] == f"chat-{msg_id}"
    assert sent[0].android.notification.tag == f"gms-chat-{cust['id']}"
    assert _rows(env, prov["id"]) == []                          # nothing in the page
    svc = env.make_service(prov)
    env.client.post("/api/bookings", json={"service_id": svc}, headers=env.auth(cust))
    rows = _rows(env, prov["id"])
    assert len(rows) == 1 and rows[0].type == "booking_new"      # bookings still saved


def test_old_chat_rows_are_hidden_from_page_and_counts(env):
    u = env.make_user("Una")
    db = env.db_factory()
    try:
        db.add(Notification(user_id=u["id"], title="old chat", body="x",
                            type="chat", ref_id=1, data={}))
        db.add(Notification(user_id=u["id"], title="Booking update", body="y",
                            type="booking_status", ref_id=7, data={}))
        db.commit()
    finally:
        db.close()
    h = env.auth(u)
    page = env.client.get("/api/notifications", headers=h).json()
    items = page.get("notifications") or page.get("items") or []
    assert [i["title"] for i in items] == ["Booking update"]
    assert env.client.get("/api/notifications/unread-count", headers=h).json()["unread"] == 1
    u2 = env.client.get("/api/notifications/booking-unseen", headers=h).json()
    assert u2["unread_total"] == 1 and u2["count"] == 1


def test_bell_count_drops_only_when_notifications_are_read(env):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(prov)
    for _ in range(3):
        env.client.post("/api/bookings", json={"service_id": svc}, headers=env.auth(cust))
    h = env.auth(prov)
    count = lambda: env.client.get("/api/notifications/unread-count", headers=h).json()["unread"]  # noqa: E731
    assert count() == 3
    env.client.get("/api/bookings/received", headers=h)          # browsing clears nothing
    assert count() == 3
    nid = _rows(env, prov["id"])[0].id
    env.client.put(f"/api/notifications/{nid}/read", json={}, headers=h)
    assert count() == 2


def test_push_only_requires_its_own_id(env):
    db = env.db_factory()
    try:
        try:
            notify_mod.notify(db, 1, "t", "b", type_="chat", history=False, data={})
            raise AssertionError("expected an assertion")
        except AssertionError as e:
            assert "notif_id" in str(e)
    finally:
        db.rollback()
        db.close()


def test_fcm_calls_are_time_bounded():
    # firebase-admin's default is 120 s per call (+ retries): one stalled
    # call held a push worker for minutes and later pushes queued behind it.
    assert notify_mod.FCM_HTTP_TIMEOUT_S == 10
