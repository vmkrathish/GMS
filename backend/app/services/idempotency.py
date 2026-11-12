# ─────────────────────────────────────────────
# app/services/idempotency.py
#
# Replay protection for the routes that create something AND send a
# push (chat send, booking create, booking action).
#
# Why this exists: the Flutter client retries a request once on a
# timeout (api_service.dart). On Render's free tier the FIRST attempt
# often times out while the server is still waking up, yet is later
# processed — so the retry would create a duplicate message/booking and
# a second push. The client now sends an `Idempotency-Key` header
# (one fresh key per user action, REUSED on the retry); the server
# returns the first request's stored response for any repeat.
#
# How it stays correct:
#   • claim() inserts the key row inside a SAVEPOINT in the caller's own
#     transaction, so the key commits (or rolls back) together with the
#     message/booking it guards — a failed request leaves no key behind.
#   • A concurrent duplicate blocks on the UNIQUE index until the first
#     transaction finishes, then either gets IntegrityError (first one
#     committed → we return its stored response) or proceeds (first one
#     rolled back → this attempt legitimately does the work).
#   • Only successful (2xx) responses are stored; a validation error is
#     simply recomputed on retry.
#   • No header → no behaviour change (old clients keep working).
# ─────────────────────────────────────────────
import logging
import re
import time

from fastapi import Request
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models.models import IdempotencyKey

log = logging.getLogger("gms.idempotency")

HEADER = "Idempotency-Key"
_KEY_RE = re.compile(r"^[A-Za-z0-9_\-:.]{8,100}$")
KEY_TTL_HOURS = 48
_PURGE_EVERY = 50          # opportunistic cleanup: once per N claims
_claims_since_purge = 0

# Is the idempotency_keys table there? Checked at most once a minute per
# process (one cheap catalog query), so applying the migration in
# Supabase switches protection on without a redeploy or restart.
_CHECK_EVERY_S = 60.0
_table_state = {"ok": None, "checked_at": 0.0}


def table_available(db: Session) -> bool:
    now = time.monotonic()
    if _table_state["ok"] is not None and now - _table_state["checked_at"] < _CHECK_EVERY_S:
        return _table_state["ok"]
    try:
        ok = bool(db.execute(text(
            "SELECT to_regclass('public.idempotency_keys') IS NOT NULL")).scalar())
    except Exception:  # noqa: BLE001 — a failed check must not block the action
        log.warning("idempotency: table check failed", exc_info=True)
        ok = False
    if not ok and _table_state["ok"] is not False:
        log.error("idempotency: table idempotency_keys is MISSING — chat/booking "
                  "writes run WITHOUT duplicate-retry protection. Apply "
                  "backend/sql/add_push_reliability.sql (after its precheck).")
    _table_state.update(ok=ok, checked_at=now)
    return ok


# ── In-memory fallback while idempotency_keys is missing ───────────────
# Keeps a retried request with the SAME key (e.g. a notification Reply
# that timed out on the phone and was retried) from saving twice. Lives in
# this process only (lost on restart / not shared between instances), so
# it is a stop-gap: the durable protection is the migration.
_MEM_TTL_S = 15 * 60
_MEM_MAX = 10_000
_mem_store: dict[tuple, tuple[float, int, dict]] = {}


class _MemClaim:
    def __init__(self, k: tuple):
        self.k = k
        self.status_code = None
        self.response = None


def _mem_get(k: tuple):
    hit = _mem_store.get(k)
    if hit is None:
        return None
    if time.monotonic() - hit[0] > _MEM_TTL_S:
        _mem_store.pop(k, None)
        return None
    return hit


def _remember_after_commit(session) -> None:
    for h in session.info.pop("_idem_mem", []):
        if h.response is not None:
            if len(_mem_store) >= _MEM_MAX:
                _mem_store.pop(next(iter(_mem_store)))
            _mem_store[h.k] = (time.monotonic(), h.status_code, h.response)


def _forget_on_rollback(session) -> None:
    session.info.pop("_idem_mem", None)


from sqlalchemy import event as _sa_event  # noqa: E402
_sa_event.listen(Session, "after_commit", _remember_after_commit)
_sa_event.listen(Session, "after_rollback", _forget_on_rollback)


def reset_table_check() -> None:
    """Forget the cached answer (tests, or after applying the migration)."""
    _table_state.update(ok=None, checked_at=0.0)


def key_from_request(request: Request) -> str | None:
    """Returns the client's key, or None if absent/malformed (a bad key
    is ignored rather than rejected so it can never block a real action)."""
    raw = (request.headers.get(HEADER) or "").strip()
    if raw and _KEY_RE.match(raw):
        return raw
    return None


def _stored_response(row: IdempotencyKey) -> JSONResponse | None:
    if row is None or row.response is None:
        return None
    return JSONResponse(status_code=row.status_code or 200, content=row.response)


def _lookup(db: Session, user_id: int, scope: str, key: str) -> IdempotencyKey | None:
    return (db.query(IdempotencyKey)
            .filter(IdempotencyKey.user_id == user_id,
                    IdempotencyKey.scope == scope,
                    IdempotencyKey.key == key)
            .first())


def _maybe_purge(db: Session) -> None:
    global _claims_since_purge
    _claims_since_purge += 1
    if _claims_since_purge < _PURGE_EVERY:
        return
    _claims_since_purge = 0
    try:
        db.execute(text(
            "DELETE FROM idempotency_keys WHERE id IN ("
            " SELECT id FROM idempotency_keys"
            " WHERE created_at < NOW() - make_interval(hours => :h) LIMIT 200)"),
            {"h": KEY_TTL_HOURS})
    except Exception:  # cleanup must never break a real request
        log.warning("idempotency: purge failed", exc_info=True)


def claim(db: Session, user_id: int, scope: str, key: str | None):
    """Returns (replay_response, handle).

    * replay_response is not None → this key already completed: return it
      as-is and do NOT do the work again.
    * otherwise handle is the claimed row (or None when no key was sent);
      the caller does its work then calls complete(handle, ...) BEFORE
      committing so the stored response commits atomically with the work.
    """
    if not key:
        return None, None
    if not table_available(db):
        # Production without add_push_reliability.sql: querying the
        # missing table raised UndefinedTable and turned EVERY chat send /
        # booking create / booking action into a 500. Do the real work,
        # with the in-memory stand-in for retry protection (only a
        # COMMITTED response is ever replayed).
        k = (user_id, scope, key)
        hit = _mem_get(k)
        if hit is not None:
            return JSONResponse(status_code=hit[1], content=hit[2]), None
        h = _MemClaim(k)
        db.info.setdefault("_idem_mem", []).append(h)
        return None, h

    existing = _lookup(db, user_id, scope, key)
    if existing is not None:
        replay = _stored_response(existing)
        if replay is not None:
            log.info("idempotency: replay scope=%s user_id=%s", scope, user_id)
            return replay, None
        # A committed row with no response can't be an in-flight request
        # (those are invisible until they commit) — it's an orphan left
        # when an earlier attempt committed mid-way (e.g. apply_expiry)
        # and then failed validation. Adopt it so this attempt is guarded.
        return None, existing

    for _attempt in range(2):
        row = IdempotencyKey(user_id=user_id, scope=scope, key=key)
        try:
            with db.begin_nested():       # SAVEPOINT: outer txn stays usable
                db.add(row)
                db.flush()
            _maybe_purge(db)
            return None, row
        except IntegrityError:
            # A concurrent request with the same key won (its commit is
            # what released our wait). Serve its stored response.
            existing = _lookup(db, user_id, scope, key)
            replay = _stored_response(existing) if existing else None
            if replay is not None:
                log.info("idempotency: concurrent duplicate served from "
                         "stored response scope=%s user_id=%s", scope, user_id)
                return replay, None
            if existing is not None:
                return None, existing          # orphan, see above
            # Winner rolled back (nothing visible) → loop and claim.
    # Extremely unlikely: fall through without protection rather than
    # fail the user's real action.
    log.warning("idempotency: could not claim key scope=%s user_id=%s",
                scope, user_id)
    return None, None


def complete(handle: IdempotencyKey | None, status_code: int, content: dict) -> None:
    """Attach the response to the claimed key (same transaction)."""
    if handle is None:
        return
    handle.status_code = status_code
    handle.response = content
