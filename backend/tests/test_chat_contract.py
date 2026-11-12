# Chat contract (both directions) + how database failures reach clients.
# The app and the web client use the same endpoints, so "Android -> Web"
# and "Web -> Android" are the same two calls with the roles swapped.
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.core import security
from app.database.session import get_db
from app.main import app
from app.models.models import User

ORIGIN = {"Origin": "http://localhost:59995"}   # a Flutter web dev origin


def _user(env, phone, name):
    db = env.db_factory()
    try:
        u = User(phone=phone, name=name, email=f"{phone}@example.test",
                 password_hash=security.hash_password("pw-12345"))
        db.add(u)
        db.commit()
        return {"id": u.id, "phone": u.phone, "name": u.name}
    finally:
        db.close()


def test_messages_flow_both_directions_and_persist(env):
    a = _user(env, "9876511111", "Android User")
    b = _user(env, "9876522222", "Web User")
    ha, hb = env.auth(a), env.auth(b)

    r = env.client.post(f"/api/chats/{b['id']}", json={"body": "hello from A"}, headers=ha)
    assert r.status_code in (200, 201) and r.json()["success"] is True
    r = env.client.post(f"/api/chats/{a['id']}", json={"body": "reply from B"}, headers=hb)
    assert r.status_code in (200, 201) and r.json()["success"] is True

    for viewer, partner in ((hb, a), (ha, b)):
        thread = env.client.get(f"/api/chats/{partner['id']}", headers=viewer)
        assert thread.status_code == 200
        bodies = [m["body"] for m in thread.json()["messages"]]
        assert bodies == ["hello from A", "reply from B"]
        convs = env.client.get("/api/chats", headers=viewer).json()
        assert any(c.get("partner_id") == partner["id"] for c in convs["conversations"])


def test_send_without_session_is_401_with_cors(env):
    b = _user(env, "9876533333", "Someone")
    r = env.client.post(f"/api/chats/{b['id']}", json={"body": "x"}, headers=ORIGIN)
    assert r.status_code == 401
    assert r.headers.get("access-control-allow-origin") == "*"


def _auth_failing_engine(url):
    """An engine whose every connection attempt fails exactly the way
    psycopg2 reports Render's error. (The local test server trusts
    localhost connections, so a wrong password alone would not fail.)"""
    import psycopg2

    def _connect():
        raise psycopg2.OperationalError(
            'connection to server at "pooler.example" failed: FATAL:  '
            'password authentication failed for user "postgres"')
    return create_engine(url.set(password="definitely-wrong"), creator=_connect)


@pytest.fixture()
def broken_db(env, engine):
    """Request handling uses a database that rejects the password — the
    failure Render logged ('password authentication failed ...')."""
    bad = _auth_failing_engine(engine.url)
    Bad = sessionmaker(bind=bad, autoflush=False)

    def _bad_db():
        db = Bad()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = _bad_db
    yield
    app.dependency_overrides.pop(get_db, None)
    bad.dispose()


def test_database_auth_failure_is_reported_as_server_error_with_cors(env, broken_db):
    a = _user(env, "9876544444", "A")
    r = env.client.post("/api/chats/1", json={"body": "x"},
                        headers={**env.auth(a), **ORIGIN})
    # Before the fix: plain 500 WITHOUT CORS headers, which a browser
    # turns into a network error -> "please check your connection".
    assert r.status_code == 503
    assert r.headers.get("access-control-allow-origin") == "*"
    body = r.json()
    assert body["success"] is False and "database" in body["message"].lower()
    assert "definitely-wrong" not in r.text


def test_health_db_reports_auth_failure_without_secrets(env, engine, monkeypatch):
    import app.main as main
    bad = _auth_failing_engine(engine.url)
    monkeypatch.setattr(main, "_db_engine", bad)
    out = env.client.get("/health?db=1").json()
    assert out["db"] == "unavailable" and out["db_error"] == "auth_failed"
    assert "definitely-wrong" not in str(out)
    bad.dispose()
