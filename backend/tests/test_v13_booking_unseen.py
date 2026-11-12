# V13: booking-event unseen counts / "New" markers, View vs open-booking,
# and actor-correct labels.
from app.models.models import Notification


def _act(env, user, bid, action, **extra):
    return env.client.put(f"/api/bookings/{bid}/action",
                          json={"action": action, **extra}, headers=env.auth(user))


def _book(env, cust, svc):
    r = env.client.post("/api/bookings", json={"service_id": svc}, headers=env.auth(cust))
    assert r.status_code in (200, 201), r.text
    return r.json()["booking"]["id"]


def _unseen(env, user):
    r = env.client.get("/api/notifications/booking-unseen", headers=env.auth(user))
    assert r.status_code == 200
    return r.json()


def _last_notif(env, user_id):
    db = env.db_factory()
    try:
        return db.query(Notification).filter_by(user_id=user_id).order_by(
            Notification.id.desc()).first()
    finally:
        db.close()


def test_each_event_counted_once_and_retries_do_not_inflate(env):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(prov)
    b1, b2 = _book(env, cust, svc), _book(env, cust, svc)
    u = _unseen(env, prov)
    assert u["count"] == 2 and u["by_booking"] == {str(b1): 1, str(b2): 1}
    assert _act(env, prov, b1, "accept").status_code == 200
    assert _act(env, prov, b1, "accept").status_code == 400      # retry → no new event
    assert _unseen(env, cust)["count"] == 1
    # the provider's count did not change from the provider's own action
    assert _unseen(env, prov)["count"] == 2


def test_view_marks_one_event_and_open_booking_marks_that_booking(env):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(prov)
    b1, b2 = _book(env, cust, svc), _book(env, cust, svc)
    h = env.auth(prov)
    # View on the b2 notification → only that event
    nid = _last_notif(env, prov["id"]).id
    for _ in range(2):
        env.client.put(f"/api/notifications/{nid}/read", json={}, headers=h)
    u = _unseen(env, prov)
    assert u["count"] == 1 and str(b2) not in u["by_booking"]
    # just listing bookings / unseen never clears anything
    env.client.get("/api/bookings/received", headers=h)
    assert _unseen(env, prov)["count"] == 1
    # opening b1's details in the app → b1 seen, once
    assert env.client.put(f"/api/bookings/{b1}/seen", headers=h).status_code in (404, 405)
    r = env.client.put(f"/api/notifications/booking/{b1}/seen", headers=h)
    assert r.json()["updated"] == 1
    assert env.client.put(f"/api/notifications/booking/{b1}/seen",
                          headers=h).json()["updated"] == 0
    assert _unseen(env, prov)["count"] == 0
    # the pending request itself is untouched (still needs an answer)
    rows = env.client.get("/api/bookings/received", headers=h).json()["bookings"]
    assert {r["status"] for r in rows if r["id"] in (b1, b2)} == {"pending"}


def test_unseen_is_per_user(env):
    prov, cust, other = env.make_user("Prov"), env.make_user("Cust"), env.make_user("Oli")
    svc = env.make_service(prov)
    b = _book(env, cust, svc)
    assert env.client.put(f"/api/notifications/booking/{b}/seen",
                          headers=env.auth(other)).json()["updated"] == 0
    assert _unseen(env, prov)["count"] == 1
    assert _unseen(env, other)["count"] == 0
    assert env.client.get("/api/notifications/booking-unseen").status_code == 401


def test_labels_name_the_actor(env):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(prov)
    b = _book(env, cust, svc)
    assert _act(env, cust, b, "cancel", reason="plans changed").status_code == 200
    assert _last_notif(env, prov["id"]).title == "Cancelled by the customer"
    b = _book(env, cust, svc)
    assert _act(env, prov, b, "cancel", reason="unwell").status_code == 200
    assert _last_notif(env, cust["id"]).title == "Cancelled by the provider"
