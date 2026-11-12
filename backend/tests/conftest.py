# ─────────────────────────────────────────────
# Test harness for the push-notification pipeline.
#
# Runs against a REAL PostgreSQL (transactions, row locks, partial
# unique indexes and savepoints are the things under test — SQLite
# cannot prove them). Provide a throwaway database:
#
#   export TEST_DATABASE_URL=postgresql+psycopg2://USER:PASS@localhost:5432/gms_test
#   pytest
#
# SAFETY: the schema is dropped and recreated, so the database name
# MUST contain "test" or the whole run is refused.
#
# Firebase is never contacted: FCM is replaced by FakeFCM, and the
# worker pool by a recorder, so every test is deterministic.
# ─────────────────────────────────────────────
import os
import threading

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL")

# app.database.session builds its engine at IMPORT time from
# app.core.env_config.DATABASE_URL (config.py forces that value). Point it
# at the test database (or a harmless dummy when none is configured) BEFORE
# any `app.*` import, so the suite never depends on IS_ONLINE, on real or
# placeholder credentials, or on which PostgreSQL driver the bare
# "postgresql://" scheme maps to.
_SUITE_DB_URL = TEST_DB_URL or "postgresql+psycopg2://unused:unused@localhost:5432/unused_test"
# env_config refuses to import in ONLINE mode when DATABASE_URL is unset
# and the file holds placeholders — give it the test URL first. (It is
# never the real database: the URL must name a "test" database.)
os.environ["DATABASE_URL"] = _SUITE_DB_URL
os.environ.setdefault("GMS_DB_WARMUP", "0")  # no background DB thread in tests
# Never let the suite pick up a REAL Firebase Admin key (e.g. a local
# backend/secrets/firebase-service-account.json): tests use fakes and
# throwaway keys only, and must not depend on, or send with, real secrets.
os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "/nonexistent/gms-tests-use-no-real-firebase-key.json"
import app.core.env_config as _env_config  # noqa: E402
_env_config.DATABASE_URL = _SUITE_DB_URL


SETUP_SQL = os.path.join(os.path.dirname(__file__), "..", "sql",
                         "gms_supabase_setup.sql")


@pytest.fixture(scope="session")
def engine():
    if not TEST_DB_URL:
        pytest.skip("TEST_DATABASE_URL not set — these tests need a real "
                    "PostgreSQL (see tests/conftest.py)")
    name = make_url(TEST_DB_URL).database or ""
    if "test" not in name.lower():
        pytest.exit(f"Refusing to run: database '{name}' does not look like "
                    f"a test database (name must contain 'test').", returncode=2)

    eng = create_engine(TEST_DB_URL, pool_pre_ping=True)

    # Build the schema from the SAME script production is built from
    # (not Base.metadata.create_all — the ORM's unnamed Enum columns
    # can't be created on PostgreSQL). This also exercises the real
    # DDL: partial unique index, idempotency table, retention trigger.
    with open(SETUP_SQL, encoding="utf-8") as fh:
        script = fh.read()
    raw = eng.raw_connection()
    try:
        cur = raw.cursor()
        cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
        cur.execute(script)
        extra = os.environ.get("TEST_EXTRA_SQL")      # optional, e.g. an RLS experiment
        if extra:
            with open(extra, encoding="utf-8") as fh:
                cur.execute(fh.read())
        raw.commit()
    finally:
        raw.close()
    yield eng
    eng.dispose()


@pytest.fixture()
def db_factory(engine):
    # Same flags as production's SessionLocal.
    return sessionmaker(bind=engine, autoflush=False, autocommit=False)


@pytest.fixture(autouse=True)
def _clean_tables(request):
    # Only touch the DB for tests that actually use it.
    if "engine" not in request.fixturenames and "env" not in request.fixturenames:
        yield
        return
    engine = request.getfixturevalue("engine")
    with engine.begin() as c:
        names = [r[0] for r in c.execute(text(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"))]
        quoted = ", ".join(f'"{n}"' for n in names)
        c.execute(text(f"TRUNCATE {quoted} RESTART IDENTITY CASCADE"))
    yield


# ───────────────────────── fakes ─────────────────────────

class FakeFCM:
    """Stands in for firebase_admin. `script[token]` is a list of
    outcomes consumed one per send attempt: None = success, or an
    exception instance to fail with."""

    def __init__(self):
        self.calls = []            # every Message ever "sent" (incl. retries)
        self.script = {}
        self.whole_call_error = None
        self.gate = None           # threading.Event: block until set
        self.entered = threading.Event()

    def __call__(self, messages):
        from app.services.notify import _Result
        self.entered.set()
        if self.gate is not None:
            self.gate.wait(timeout=10)
        if self.whole_call_error is not None:
            raise self.whole_call_error
        out = []
        for m in messages:
            self.calls.append(m)
            seq = self.script.get(m.token)
            outcome = seq.pop(0) if seq else None
            out.append(_Result(outcome is None, outcome))
        return out

    def tokens_sent(self):
        return [m.token for m in self.calls]


class PushRecorder:
    """Replaces notify._submit. mode='defer' queues until run(); 'inline'
    runs delivery immediately in the committing thread."""

    def __init__(self):
        self.mode = "defer"
        self.queued = []           # list of (fn, args)
        self.submit_count = 0

    def __call__(self, fn, *args):
        self.submit_count += 1
        if self.mode == "inline":
            fn(*args)
        else:
            self.queued.append((fn, args))

    def run(self):
        pending, self.queued = self.queued, []
        for fn, args in pending:
            fn(*args)

    def jobs(self):
        return [j for _fn, args in self.queued for j in args[0]]


class Env:
    pass


@pytest.fixture()
def env(engine, db_factory, monkeypatch):
    from app.core.security import create_access_token
    from app.database import session as session_mod
    from app.database.session import get_db
    from app.main import app
    from app.models.models import PushToken, User
    from app.services import notify as notify_mod

    e = Env()
    e.fcm = FakeFCM()
    e.push = PushRecorder()
    e.db_factory = db_factory
    e.notify = notify_mod
    e.real_submit = notify_mod._submit      # captured BEFORE it is patched
    e.real_fcm_send_each = notify_mod._fcm_send_each   # genuine SDK adapter, before the fake

    # Worker + delivery use the test database and the fakes.
    monkeypatch.setattr(session_mod, "SessionLocal", db_factory)
    monkeypatch.setattr(notify_mod, "_firebase_ready", True)
    monkeypatch.setattr(notify_mod, "_fcm_send_each", e.fcm)
    monkeypatch.setattr(notify_mod, "_submit", e.push)
    monkeypatch.setattr(notify_mod, "RETRY_BACKOFF_SECONDS", (0.0, 0.0))

    def _override_get_db():
        db = db_factory()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = _override_get_db
    e.app = app
    e.client = TestClient(app)

    _n = {"i": 0}

    def make_user(name="User"):
        _n["i"] += 1
        db = db_factory()
        try:
            u = User(phone=f"90000{_n['i']:05d}", name=name,
                     email=f"u{_n['i']}@example.test")
            db.add(u)
            db.commit()
            return {"id": u.id, "name": name, "phone": u.phone}
        finally:
            db.close()

    def auth(user):
        tok = create_access_token({"id": user["id"], "phone": user["phone"],
                                   "role": "customer", "name": user["name"]})
        return {"Authorization": f"Bearer {tok}"}

    def register(user, token, platform="android", device_id=None, client=None):
        body = {"token": token, "platform": platform}
        if device_id is not None:
            body["device_id"] = device_id
        return (client or e.client).post(
            "/api/notifications/push-token", json=body, headers=auth(user))

    def active(user_id):
        db = db_factory()
        try:
            rows = (db.query(PushToken)
                    .filter(PushToken.user_id == user_id,
                            PushToken.is_active == True)  # noqa: E712
                    .all())
            return sorted((r.token, r.device_id) for r in rows)
        finally:
            db.close()

    def all_tokens():
        db = db_factory()
        try:
            return {r.token: (r.user_id, r.device_id, r.is_active)
                    for r in db.query(PushToken).all()}
        finally:
            db.close()

    def count(model, **filters):
        db = db_factory()
        try:
            return db.query(model).filter_by(**filters).count()
        finally:
            db.close()

    def make_service(provider, price=600, title="Plumbing"):
        from app.models.models import Service, ServiceCategory
        db = db_factory()
        try:
            cat = db.query(ServiceCategory).first()
            if cat is None:
                cat = ServiceCategory(name="Plumbing")
                db.add(cat)
                db.flush()
            svc = Service(provider_id=provider["id"], category_id=cat.id,
                          title=title, price=price, city="Chennai")
            db.add(svc)
            db.commit()
            return svc.id
        finally:
            db.close()

    e.make_user, e.auth, e.register = make_user, auth, register
    e.make_service = make_service
    e.active, e.all_tokens, e.count = active, all_tokens, count
    yield e
    app.dependency_overrides.pop(get_db, None)
