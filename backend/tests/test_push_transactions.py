"""Fix 3: push only after commit, never for rollbacks, never blocking the
response, and never duplicated by retried requests."""
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from app.models.models import (Booking, BookingEvent, IdempotencyKey, Message,
                               Notification)
from app.services import idempotency as idem
from app.services import notify as notify_mod
from app.services.notify import notify

KEY1 = "idem-key-0000000001"
KEY2 = "idem-key-0000000002"


def _chat(env, sender, rcpt, body="hello", key=None, client=None):
    headers = dict(env.auth(sender))
    if key:
        headers["Idempotency-Key"] = key
    return (client or env.client).post(f"/api/chats/{rcpt['id']}",
                                       json={"body": body}, headers=headers)


@pytest.fixture()
def pair(env):
    sender, rcpt = env.make_user("Sam"), env.make_user("Riya")
    env.register(rcpt, "r-web", "web", "device-rweb-0001")
    env.register(rcpt, "r-and", "android", "device-rand-0001")
    env.register(sender, "s-and", "android", "device-sand-0001")
    return sender, rcpt


# ═════════════ commit-before-push, at the session level ═════════════

def test_push_is_held_until_commit_then_released_exactly_once(env):
    u = env.make_user("U")
    db = env.db_factory()
    try:
        notify(db, u["id"], "T", "B", type_="chat", data={"screen": "chat"})
        assert env.push.submit_count == 0            # queued, NOT sent
        assert db.info                                # …sitting on the session
        db.commit()
        assert env.push.submit_count == 1             # commit released it
        db.commit()                                   # a later commit
        assert env.push.submit_count == 1             # must not re-release
    finally:
        db.close()


def test_rollback_discards_the_push_and_the_history_row(env):
    u = env.make_user("U")
    db = env.db_factory()
    try:
        notify(db, u["id"], "T", "B")
        db.rollback()
        assert env.push.submit_count == 0
        assert not db.info.get(notify_mod._PENDING_KEY)
    finally:
        db.close()
    assert env.count(Notification, user_id=u["id"]) == 0


def test_closing_a_session_without_commit_sends_nothing(env):
    u = env.make_user("U")
    db = env.db_factory()
    notify(db, u["id"], "T", "B")
    db.close()                                        # request ended, no commit
    assert env.push.submit_count == 0
    assert env.count(Notification, user_id=u["id"]) == 0


def test_a_rolled_back_batch_does_not_leak_into_the_next_transaction(env):
    u = env.make_user("U")
    db = env.db_factory()
    try:
        notify(db, u["id"], "lost", "x")
        db.rollback()
        notify(db, u["id"], "kept", "y")
        db.commit()
        assert env.push.submit_count == 1
        titles = [j.title for j in env.push.jobs()]
        assert titles == ["kept"]
    finally:
        db.close()


def test_savepoint_rollback_does_not_discard_an_outer_pending_push(env):
    """Idempotency claims use a SAVEPOINT; its rollback must not eat a
    push that belongs to the still-live outer transaction."""
    u = env.make_user("U")
    db = env.db_factory()
    try:
        notify(db, u["id"], "T", "B")
        try:
            with db.begin_nested():
                raise RuntimeError("inner failure")
        except RuntimeError:
            pass
        db.commit()
        assert env.push.submit_count == 1
    finally:
        db.close()


def test_savepoint_rollback_drops_only_pushes_queued_inside_it(env):
    u = env.make_user("U")
    db = env.db_factory()
    try:
        notify(db, u["id"], "outer-before", "x")
        try:
            with db.begin_nested():
                notify(db, u["id"], "inner", "x")
                raise RuntimeError("inner failure")
        except RuntimeError:
            pass
        notify(db, u["id"], "outer-after", "x")
        db.commit()
        assert [j.title for j in env.push.jobs()] == ["outer-before", "outer-after"]
    finally:
        db.close()
    # …and the history rows agree with what was pushed.
    db = env.db_factory()
    try:
        titles = sorted(t for (t,) in db.execute(
            idem.text("SELECT title FROM notifications")))
    finally:
        db.close()
    assert titles == ["outer-after", "outer-before"]


def test_released_savepoint_keeps_its_pushes_until_the_real_commit(env):
    u = env.make_user("U")
    db = env.db_factory()
    try:
        with db.begin_nested():
            notify(db, u["id"], "inner", "x")
        assert env.push.submit_count == 0            # savepoint != durable
        db.commit()
        assert [j.title for j in env.push.jobs()] == ["inner"]
    finally:
        db.close()


# ═════════════ commit-before-push, through the real API ═════════════

def test_data_is_committed_and_visible_when_fcm_is_called(env, pair):
    """The decisive ordering proof: at the instant FCM is invoked, a
    SEPARATE connection can already see the committed message+history."""
    sender, rcpt = pair
    seen = {}
    real = env.fcm

    def probe(messages):
        db = env.db_factory()
        try:
            seen["messages"] = db.query(Message).count()
            seen["notifications"] = db.query(Notification).count()
        finally:
            db.close()
        return real(messages)

    env.notify._fcm_send_each = probe        # (restored by monkeypatch teardown)
    env.push.mode = "inline"
    assert _chat(env, sender, rcpt).status_code == 201
    assert seen == {"messages": 1, "notifications": 0}   # chat: push-only (V16)


def test_failed_commit_sends_no_push_and_leaves_no_rows(env, pair, monkeypatch):
    sender, rcpt = pair
    orig_commit = Session.commit

    def failing_commit(self):
        if self.info.get(notify_mod._PENDING_KEY):       # the request's commit
            raise OperationalError("COMMIT", {}, Exception("db went away"))
        return orig_commit(self)

    monkeypatch.setattr(Session, "commit", failing_commit)
    env.push.mode = "inline"
    quiet = TestClient(env.app, raise_server_exceptions=False)

    r = _chat(env, sender, rcpt, client=quiet)

    assert r.status_code == 503   # OperationalError = database unavailable (main.py middleware)
    assert env.push.submit_count == 0
    assert env.fcm.calls == []
    monkeypatch.setattr(Session, "commit", orig_commit)
    assert env.count(Message) == 0
    assert env.count(Notification) == 0


def test_booking_request_failure_after_notify_sends_no_push(env, monkeypatch):
    provider, customer = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(provider)
    env.register(provider, "p-tok", "android", "device-prov-0001")

    from app.routers import bookings as bookings_router

    def explode(*a, **k):
        raise RuntimeError("failure between notify() and commit()")

    monkeypatch.setattr(bookings_router.idem, "complete", explode)
    quiet = TestClient(env.app, raise_server_exceptions=False)
    r = quiet.post("/api/bookings", json={"service_id": svc},
                   headers=env.auth(customer))
    assert r.status_code == 500
    assert env.push.submit_count == 0
    assert env.count(Booking) == 0 and env.count(Notification) == 0


def test_rejected_workflow_action_sends_no_push(env):
    provider, customer = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(provider)
    bid = env.client.post("/api/bookings", json={"service_id": svc},
                          headers=env.auth(customer)).json()["booking"]["id"]
    env.push.queued.clear()
    before = env.push.submit_count

    r = env.client.put(f"/api/bookings/{bid}/action", json={"action": "accept"},
                       headers=env.auth(customer))       # customers can't accept
    assert r.status_code == 403
    assert env.push.submit_count == before


def test_successful_chat_releases_one_push_to_the_recipient_only(env, pair):
    sender, rcpt = pair
    assert _chat(env, sender, rcpt).status_code == 201

    jobs = env.push.jobs()
    assert [j.user_id for j in jobs] == [rcpt["id"]]      # not the sender
    env.push.run()
    assert sorted(env.fcm.tokens_sent()) == ["r-and", "r-web"]
    assert "s-and" not in env.fcm.tokens_sent()

    db = env.db_factory()
    try:
        msg = db.query(Message).filter_by(receiver_id=rcpt["id"]).one()
        assert db.query(Notification).filter_by(user_id=rcpt["id"]).count() == 0
    finally:
        db.close()
    for m in env.fcm.calls:
        assert m.data["screen"] == "chat"
        assert m.data["partner_id"] == str(sender["id"])
        assert m.data["recipient_id"] == str(rcpt["id"])
        assert m.data["notif_id"] == f"chat-{msg.id}"


# ═════════════ not blocking the response ═════════════

def test_response_returns_while_fcm_is_still_in_flight(env, pair):
    sender, rcpt = pair
    pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="test-push")
    env.notify._submit = lambda fn, *a: pool.submit(fn, *a)
    env.fcm.gate = threading.Event()                     # FCM "hangs"

    t0 = time.monotonic()
    r = _chat(env, sender, rcpt)
    elapsed = time.monotonic() - t0

    assert r.status_code == 201
    assert env.fcm.entered.wait(5), "worker never reached FCM"
    assert elapsed < 2, f"response waited on FCM ({elapsed:.2f}s)"
    assert env.fcm.calls == []                           # still blocked

    env.fcm.gate.set()                                   # let FCM finish
    pool.shutdown(wait=True)
    assert sorted(env.fcm.tokens_sent()) == ["r-and", "r-web"]


def test_real_submit_runs_delivery_on_a_worker_thread(env):
    done = threading.Event()
    seen = {}

    def job():
        seen["thread"] = threading.current_thread().name
        done.set()

    env.real_submit(job)
    assert done.wait(5)
    assert seen["thread"].startswith("gms-push")
    assert seen["thread"] != threading.current_thread().name


# ═════════════ retried requests: chat ═════════════

def test_retried_chat_with_same_key_creates_one_message_and_one_push(env, pair):
    sender, rcpt = pair
    r1 = _chat(env, sender, rcpt, "hello", key=KEY1)
    r2 = _chat(env, sender, rcpt, "hello", key=KEY1)       # the client retry

    assert r1.status_code == r2.status_code == 201
    assert r1.json() == r2.json()                           # identical response
    assert env.count(Message) == 1
    assert env.count(Notification, user_id=rcpt["id"]) == 0   # chat: push-only (V16)
    assert env.push.submit_count == 1


def test_a_different_key_is_a_different_message(env, pair):
    sender, rcpt = pair
    _chat(env, sender, rcpt, "one", key=KEY1)
    _chat(env, sender, rcpt, "two", key=KEY2)
    assert env.count(Message) == 2 and env.push.submit_count == 2


def test_requests_without_a_key_behave_exactly_as_before(env, pair):
    sender, rcpt = pair
    _chat(env, sender, rcpt, "one")
    _chat(env, sender, rcpt, "one")
    assert env.count(Message) == 2


def test_malformed_key_is_ignored_not_rejected(env, pair):
    sender, rcpt = pair
    assert _chat(env, sender, rcpt, key="bad key!").status_code == 201
    assert env.count(IdempotencyKey) == 0


def test_same_key_to_different_recipients_is_not_confused(env, pair):
    sender, rcpt = pair
    other = env.make_user("Third")
    _chat(env, sender, rcpt, "hi", key=KEY1)
    _chat(env, sender, other, "hi", key=KEY1)
    assert env.count(Message) == 2


def test_a_different_user_reusing_a_key_is_not_served_someone_elses_response(env, pair):
    sender, rcpt = pair
    _chat(env, sender, rcpt, "mine", key=KEY1)
    r = _chat(env, rcpt, sender, "theirs", key=KEY1)
    assert r.status_code == 201
    assert env.count(Message) == 2


def test_a_failed_request_does_not_consume_its_key(env, pair):
    sender, rcpt = pair
    assert _chat(env, sender, rcpt, "   ", key=KEY1).status_code == 400
    assert env.count(IdempotencyKey) == 0
    assert _chat(env, sender, rcpt, "now valid", key=KEY1).status_code == 201
    assert env.count(Message) == 1


def test_rolled_back_request_leaves_no_key_so_the_retry_does_the_work(env, pair, monkeypatch):
    sender, rcpt = pair
    from app.routers import chats as chats_router
    real_complete = chats_router.idem.complete
    monkeypatch.setattr(chats_router.idem, "complete",
                        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("x")))
    quiet = TestClient(env.app, raise_server_exceptions=False)
    assert _chat(env, sender, rcpt, key=KEY1, client=quiet).status_code == 500
    assert env.count(IdempotencyKey) == 0 and env.count(Message) == 0

    monkeypatch.setattr(chats_router.idem, "complete", real_complete)
    assert _chat(env, sender, rcpt, key=KEY1).status_code == 201
    assert env.count(Message) == 1 and env.push.submit_count == 1


def test_simultaneous_duplicate_chat_requests_create_exactly_one(env, pair):
    """The real race: original + retry in flight at once (Render waking up)."""
    sender, rcpt = pair
    statuses, ids = [], []
    barrier = threading.Barrier(4)

    def worker():
        c = TestClient(env.app)
        barrier.wait()
        r = _chat(env, sender, rcpt, "once only", key=KEY1, client=c)
        statuses.append(r.status_code)
        ids.append(r.json()["message"]["id"])

    ts = [threading.Thread(target=worker) for _ in range(4)]
    [t.start() for t in ts]
    [t.join() for t in ts]

    assert statuses == [201] * 4
    assert len(set(ids)) == 1
    assert env.count(Message) == 1
    assert env.count(Notification, user_id=rcpt["id"]) == 0   # chat: push-only (V16)
    assert env.push.submit_count == 1


# ═════════════ retried requests: bookings ═════════════

def test_retried_booking_request_creates_one_booking_and_one_push(env):
    provider, customer = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(provider)
    h = dict(env.auth(customer), **{"Idempotency-Key": KEY1})

    r1 = env.client.post("/api/bookings", json={"service_id": svc}, headers=h)
    r2 = env.client.post("/api/bookings", json={"service_id": svc}, headers=h)

    assert r1.status_code == r2.status_code == 201
    assert r1.json() == r2.json()
    assert env.count(Booking) == 1
    assert env.count(Notification, user_id=provider["id"]) == 1
    assert env.push.submit_count == 1


def _booking(env, provider, customer):
    svc = env.make_service(provider)
    return env.client.post("/api/bookings", json={"service_id": svc},
                           headers=env.auth(customer)).json()["booking"]["id"]


def test_retried_booking_action_is_a_clean_replay_not_an_error(env):
    provider, customer = env.make_user("Prov"), env.make_user("Cust")
    bid = _booking(env, provider, customer)
    before = env.push.submit_count
    h = dict(env.auth(provider), **{"Idempotency-Key": KEY1})

    r1 = env.client.put(f"/api/bookings/{bid}/action", json={"action": "accept"}, headers=h)
    r2 = env.client.put(f"/api/bookings/{bid}/action", json={"action": "accept"}, headers=h)

    assert r1.status_code == r2.status_code == 200
    assert r1.json() == r2.json()
    assert env.push.submit_count == before + 1
    assert env.count(BookingEvent, booking_id=bid, action="advance_requested") == 1
    assert env.count(Notification, user_id=customer["id"]) == 1


def test_without_a_key_a_repeat_action_is_still_rejected_by_the_state_guard(env):
    provider, customer = env.make_user("Prov"), env.make_user("Cust")
    bid = _booking(env, provider, customer)
    h = env.auth(provider)
    assert env.client.put(f"/api/bookings/{bid}/action", json={"action": "accept"}, headers=h).status_code == 200
    again = env.client.put(f"/api/bookings/{bid}/action", json={"action": "accept"}, headers=h)
    assert again.status_code == 400                         # old behaviour preserved
    assert env.count(Notification, user_id=customer["id"]) == 1


def test_simultaneous_identical_booking_actions_apply_once(env):
    """Double-tap / retry racing the original: the row lock serialises
    them, so only one transition, one event and one push happen."""
    provider, customer = env.make_user("Prov"), env.make_user("Cust")
    bid = _booking(env, provider, customer)
    before = env.push.submit_count
    statuses = []
    barrier = threading.Barrier(3)

    def worker():
        c = TestClient(env.app)
        barrier.wait()
        r = c.put(f"/api/bookings/{bid}/action", json={"action": "accept"},
                  headers=env.auth(provider))
        statuses.append(r.status_code)

    ts = [threading.Thread(target=worker) for _ in range(3)]
    [t.start() for t in ts]
    [t.join() for t in ts]

    assert sorted(statuses) == [200, 400, 400]
    assert env.count(BookingEvent, booking_id=bid, action="advance_requested") == 1
    assert env.push.submit_count == before + 1


def test_status_compat_route_still_works_and_pushes_once(env):
    provider, customer = env.make_user("Prov"), env.make_user("Cust")
    bid = _booking(env, provider, customer)
    before = env.push.submit_count
    r = env.client.put(f"/api/bookings/{bid}/status", json={"status": "accepted"},
                       headers=env.auth(provider))
    assert r.status_code == 200
    assert env.push.submit_count == before + 1


# ═════════════ housekeeping ═════════════

def test_expired_idempotency_keys_are_purged_but_fresh_ones_kept(env):
    u = env.make_user("U")
    db = env.db_factory()
    try:
        db.execute(idem.text(
            "INSERT INTO idempotency_keys(user_id,scope,key,status_code,response,created_at)"
            " VALUES (:u,'s','old-key-00000001',201,'{}', NOW() - INTERVAL '5 days'),"
            "        (:u,'s','new-key-00000001',201,'{}', NOW())"), {"u": u["id"]})
        db.commit()
        idem._claims_since_purge = idem._PURGE_EVERY - 1
        idem._maybe_purge(db)
        db.commit()
        keys = [k for (k,) in db.execute(idem.text("SELECT key FROM idempotency_keys"))]
        assert keys == ["new-key-00000001"]
    finally:
        db.close()
