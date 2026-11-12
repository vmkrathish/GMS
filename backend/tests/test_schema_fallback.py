# Production can run this backend before backend/sql/add_push_reliability.sql
# has been applied. Then the idempotency_keys table does not exist and —
# before the fix — every chat send / booking create / booking action that
# carried an Idempotency-Key header (all of them, from the Flutter app)
# failed with UndefinedTable -> 500, which the web app reported as
# "Can't reach the GMS server". Reads and login kept working.
import pytest
from sqlalchemy import text

from app.services import idempotency as idem
from app.models.models import Message

ORIGIN = {"Origin": "http://localhost:62898"}


@pytest.fixture()
def no_idempotency_table(env, engine):
    with engine.begin() as c:
        c.execute(text("ALTER TABLE idempotency_keys RENAME TO idempotency_keys_hidden"))
    idem.reset_table_check()
    try:
        yield
    finally:
        with engine.begin() as c:
            c.execute(text("ALTER TABLE idempotency_keys_hidden RENAME TO idempotency_keys"))
        idem.reset_table_check()


def _h(env, user, key):
    return {**env.auth(user), "Idempotency-Key": key, **ORIGIN}


def test_chat_send_works_without_the_migration(env, no_idempotency_table):
    a, b = env.make_user("Ann"), env.make_user("Bob")
    r = env.client.post(f"/api/chats/{b['id']}", json={"body": "hi"},
                        headers=_h(env, a, "chat-key-0001-abcdef"))
    assert r.status_code in (200, 201), r.text
    assert r.headers.get("access-control-allow-origin") == "*"
    thread = env.client.get(f"/api/chats/{a['id']}", headers=env.auth(b)).json()
    assert [m["body"] for m in thread["messages"]] == ["hi"]


def test_booking_create_and_action_work_without_the_migration(env, no_idempotency_table):
    prov, cust = env.make_user("Prov"), env.make_user("Cust")
    svc = env.make_service(prov)
    r = env.client.post("/api/bookings", json={"service_id": svc},
                        headers=_h(env, cust, "book-key-0001-abcdef"))
    assert r.status_code in (200, 201), r.text
    bid = r.json()["booking"]["id"]
    r = env.client.put(f"/api/bookings/{bid}/action", json={"action": "accept"},
                       headers=_h(env, prov, "act-key-0001-abcdef"))
    assert r.status_code == 200, r.text


def test_profile_update_works_without_the_migration(env, no_idempotency_table):
    u = env.make_user("Prof")
    r = env.client.put("/api/users/me", json={"name": "Prof Renamed"},
                       headers={**env.auth(u), **ORIGIN})
    assert r.status_code == 200, r.text


def test_health_reports_whether_the_migration_is_applied(env, engine):
    assert env.client.get("/health?db=1").json()["push_reliability_migration"] is True
    with engine.begin() as c:
        c.execute(text("ALTER TABLE idempotency_keys RENAME TO idempotency_keys_hidden"))
    try:
        assert env.client.get("/health?db=1").json()["push_reliability_migration"] is False
    finally:
        with engine.begin() as c:
            c.execute(text("ALTER TABLE idempotency_keys_hidden RENAME TO idempotency_keys"))
        idem.reset_table_check()


def test_retry_protection_resumes_once_the_table_exists(env):
    a, b = env.make_user("Ann"), env.make_user("Bob")
    h = _h(env, a, "chat-key-0002-abcdef")
    for _ in range(2):
        assert env.client.post(f"/api/chats/{b['id']}", json={"body": "once"},
                               headers=h).status_code in (200, 201)
    assert env.count(Message) == 1
