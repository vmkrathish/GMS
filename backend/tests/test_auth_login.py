# Login / session behaviour (fresh login, re-login, wrong password, unknown
# account, expired + forged tokens, timing headers, bcrypt cost migration,
# DB warm-up health check). Needs TEST_DATABASE_URL like the other suites.
from datetime import datetime, timedelta, timezone

import pytest
from jose import jwt

from app.core import security
from app.core.config import settings
from app.models.models import User

PASSWORD = "correct horse 42"


@pytest.fixture()
def account(env):
    e = env
    db = e.db_factory()
    try:
        u = User(phone="9876500001", name="Login Tester", email="login@example.test",
                 password_hash=security.hash_password(PASSWORD))
        db.add(u)
        db.commit()
        return {"id": u.id, "phone": u.phone, "email": u.email, "name": u.name}
    finally:
        db.close()


def _login(e, identifier, password=PASSWORD):
    return e.client.post("/api/auth/login",
                         json={"identifier": identifier, "password": password})


def _stored_hash(e, user_id):
    db = e.db_factory()
    try:
        return db.get(User, user_id).password_hash
    finally:
        db.close()


def test_fresh_login_by_phone_and_email_returns_working_token(env, account):
    for ident in (account["phone"], account["email"].upper(), "+91 98765 00001"):
        r = _login(env, ident)
        assert r.status_code == 200, (ident, r.text)
        body = r.json()
        assert body["success"] is True and body["user"]["id"] == account["id"]
        me = env.client.get("/api/users/me",
                            headers={"Authorization": f"Bearer {body['token']}"})
        assert me.status_code == 200


def test_login_reports_server_timing(env, account):
    r = _login(env, account["phone"])
    st = r.headers.get("server-timing", "")
    for part in ("db;dur=", "hash;dur=", "total;dur="):
        assert part in st
    assert r.headers.get("timing-allow-origin") == "*"


def test_wrong_password_and_unknown_account(env, account):
    r = _login(env, account["phone"], "nope")
    assert r.status_code == 401 and r.json()["success"] is False
    assert r.json()["message"] == "Incorrect password."
    r = _login(env, "9123400000")
    assert r.status_code == 404 and r.json()["notRegistered"] is True
    r = _login(env, "", "x")
    assert r.status_code == 400


def test_relogin_after_logout_works_and_old_tokens_stay_valid(env, account):
    # The backend is stateless JWT: "logout" is client-side. Logging in
    # again must work, and a second device's token is unaffected.
    t1 = _login(env, account["phone"]).json()["token"]
    t2 = _login(env, account["phone"]).json()["token"]
    for t in (t1, t2):
        assert env.client.get("/api/users/me",
                              headers={"Authorization": f"Bearer {t}"}).status_code == 200


def test_expired_and_forged_tokens_are_rejected_with_401(env, account):
    expired = jwt.encode({"id": account["id"], "phone": account["phone"], "role": "customer",
                          "name": "x", "exp": datetime.now(timezone.utc) - timedelta(minutes=1)},
                         settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM)
    forged = jwt.encode({"id": account["id"], "phone": account["phone"], "role": "customer",
                         "name": "x", "exp": datetime.now(timezone.utc) + timedelta(days=1)},
                        "not-the-secret", algorithm=settings.JWT_ALGORITHM)
    for tok in (expired, forged):
        r = env.client.get("/api/users/me", headers={"Authorization": f"Bearer {tok}"})
        assert r.status_code == 401 and r.json()["success"] is False
    assert env.client.get("/api/users/me").status_code == 401


def test_bcrypt_cost_change_rehashes_once_on_login(env, account, monkeypatch):
    assert _stored_hash(env, account["id"]).startswith("$2b$12$")
    monkeypatch.setattr(settings, "BCRYPT_ROUNDS", 4)
    assert _login(env, account["phone"]).status_code == 200
    assert _stored_hash(env, account["id"]).startswith("$2b$04$")
    # Next login: same cost -> no rehash; password still works.
    r = _login(env, account["phone"])
    assert r.status_code == 200 and "rehash;dur=0.0" in r.headers["server-timing"]
    # Wrong password never triggers a rehash.
    before = _stored_hash(env, account["id"])
    monkeypatch.setattr(settings, "BCRYPT_ROUNDS", 5)
    assert _login(env, account["phone"], "bad").status_code == 401
    assert _stored_hash(env, account["id"]) == before


def test_needs_rehash_parsing(monkeypatch):
    monkeypatch.setattr(settings, "BCRYPT_ROUNDS", 12)
    assert security.needs_rehash("$2b$10$abc") is True
    assert security.needs_rehash("$2b$12$abc") is False
    assert security.needs_rehash(None) is False and security.needs_rehash("garbage") is False


def test_health_plain_and_with_db_warmup(env):
    plain = env.client.get("/health").json()
    assert plain["success"] is True and "db" not in plain
    deep = env.client.get("/health?db=1").json()
    assert deep["db"] == "ok" and deep["db_ms"] >= 0


def test_presence_update_is_written_and_parallel_requests_do_not_queue(env, account):
    import concurrent.futures as cf
    from app.models.models import User as U
    db = env.db_factory()
    try:
        db.get(U, account["id"]).last_seen_at = None
        db.commit()
    finally:
        db.close()
    h = env.auth(account)
    with cf.ThreadPoolExecutor(5) as ex:
        codes = list(ex.map(lambda _: env.client.get("/api/users/me", headers=h).status_code,
                            range(5)))
    assert codes == [200] * 5
    db = env.db_factory()
    try:
        assert db.get(U, account["id"]).last_seen_at is not None
    finally:
        db.close()


def test_health_reports_whether_push_is_enabled(env, monkeypatch):
    from app.services import notify
    monkeypatch.setattr(notify, "_firebase_ready", False)
    assert env.client.get("/health").json()["push"] is False
    monkeypatch.setattr(notify, "_firebase_ready", True)
    assert env.client.get("/health").json()["push"] is True
