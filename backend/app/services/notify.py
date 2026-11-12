# Notification service — durable in-app history + FCM push to every
# active device the user is logged into.
#
# Contract (changed from the original, deliberately):
#
#   notify(db, ...)  — called INSIDE a request's transaction. It only
#                      (a) inserts the notification-history row and
#                      (b) QUEUES a push on the session. It never talks
#                      to Firebase and never blocks.
#
#   After the request's transaction COMMITS, a SQLAlchemy `after_commit`
#   hook hands the queued push to a small worker pool. If the
#   transaction ROLLS BACK (or the session is closed without commit),
#   an `after_rollback` hook discards the queue — so a push can never
#   announce a message/booking that does not exist.
#
#   The worker uses its OWN database session (the request's session is
#   closed by then) and sends via FCM, so:
#     • the API response is not held up by FCM round trips,
#     • one failing device never affects the others,
#     • the history row exists whether or not push succeeds.
#
# Why session hooks rather than FastAPI BackgroundTasks: the booking
# engine commits inside a service function, so a route-level
# BackgroundTasks call can't observe it, and every route would need a
# new parameter. The hook gives "push only after commit" to every
# current and future notify() caller with no call-site changes.
import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

from sqlalchemy import event, text
from sqlalchemy.orm import Session

from app.core.config import settings
# Imported as a module (not `from ... import SessionLocal`) so the
# worker always uses whatever factory is current — tests swap it.
from app.database import session as _db_session
from app.models.models import Notification, PushToken

log = logging.getLogger("gms.notify")

_firebase_ready = False
# Seconds per FCM HTTP call (firebase-admin default: 120).
FCM_HTTP_TIMEOUT_S = 10

try:  # pragma: no cover
    if os.path.exists(settings.GOOGLE_APPLICATION_CREDENTIALS):
        import firebase_admin
        from firebase_admin import credentials

        firebase_admin.initialize_app(
            credentials.Certificate(settings.GOOGLE_APPLICATION_CREDENTIALS),
            # firebase-admin's default HTTP timeout is 120 s (plus its own
            # retries). One stalled FCM call then held a push worker for
            # minutes and every later push queued behind it. 10 s bounds
            # that; our own retry loop below still retries once.
            {"httpTimeout": FCM_HTTP_TIMEOUT_S},
        )
        _firebase_ready = True
        log.info("notify: Firebase Admin SDK initialized")
    else:
        # WARNING, not info: a server without this file silently sends no
        # pushes at all — the most common reason "notifications don't work".
        log.warning("notify: no Firebase credential file at %s — push disabled, "
                    "notification history still works",
                    settings.GOOGLE_APPLICATION_CREDENTIALS)
except Exception as e:
    _firebase_ready = False
    log.warning("notify: Firebase init failed (%s: %s) — push disabled, "
               "notification history still works", type(e).__name__, e)


def push_to_device(user_id: int, device_id: str, title: str, body: str,
                   data: dict | None = None) -> None:
    """One push to ONE device of the user, no history row and nothing to
    commit (used for the login welcome). Other devices never get it."""
    payload = {str(k): "" if v is None else str(v) for k, v in (data or {}).items()}
    payload.setdefault("recipient_id", str(user_id))
    _submit(deliver_push, PushJob(user_id=user_id, title=title, body=body,
                                  data=payload, device_id=device_id))


def push_enabled() -> bool:
    """True when the Firebase Admin SDK is initialised (GET /health shows it)."""
    return _firebase_ready


ANDROID_CHANNEL_ID = "gms_default_channel"   # must match AndroidManifest.xml

# Transient FCM failures (5xx/quota/timeouts) are retried a couple of
# times with a short backoff; permanent ones are logged and skipped.
MAX_SEND_ATTEMPTS = 3
RETRY_BACKOFF_SECONDS = (1.0, 3.0)

_PENDING_KEY = "gms_pending_pushes"


@dataclass(frozen=True)
class PushJob:
    """One push, fully resolved. Plain values only — it outlives the
    request's session, so it must not hold ORM objects."""
    user_id: int
    title: str
    body: str
    data: dict   # str -> str; includes notif_id / type / recipient_id
    # Only this device's tokens (e.g. the login welcome). None = every
    # active device of the user (all real events).
    device_id: str | None = None
    # monotonic time the push was queued — logs "queued→FCM" latency.
    queued_at: float = field(default_factory=time.monotonic)


@dataclass(frozen=True)
class _Target:
    id: int
    token: str
    platform: str


# ───────────────────────── queueing (request side) ─────────────────────

def notify(db: Session, user_id: int, title: str, body: str,
           type_: str = "general", ref_id: int | None = None,
           data: dict | None = None, history: bool = True) -> None:
    """Queues the push and (by default) inserts the in-app history row.
    Does NOT commit — the caller's commit is what releases the push (see
    module header). history=False (chat messages): push only, nothing in
    the in-app Notifications page; data must then carry a unique
    "notif_id" (e.g. "chat-<message id>") for the web tag.
    """
    if history:
        n = Notification(user_id=user_id, title=title, body=body,
                         type=type_, ref_id=ref_id, data=data or {})
        db.add(n)
        # The session is autoflush=False; flush so the row has an id. The
        # id rides in the push as a stable per-notification identifier
        # (the web service worker uses it as the notification `tag`, so
        # even an accidental double delivery collapses into ONE visible
        # notification). Still inside the caller's transaction.
        db.flush()
        notif_id = str(n.id)
    else:
        notif_id = str((data or {}).get("notif_id") or "")
        assert notif_id, "push-only notifications need data['notif_id']"

    payload = {str(k): "" if v is None else str(v)
               for k, v in (data or {}).items()}
    payload.update({"notif_id": notif_id, "type": type_,
                    "recipient_id": str(user_id)})
    # Remember WHICH (sub)transaction queued this push: if only a
    # SAVEPOINT is rolled back, just the pushes queued inside it are
    # dropped; the outer transaction's pushes survive.
    txn = db.get_nested_transaction() or db.get_transaction()
    db.info.setdefault(_PENDING_KEY, []).append(
        (txn, PushJob(user_id=user_id, title=title, body=body, data=payload)))
    log.info("notify: event created — type=%s recipient user_id=%s "
             "notif_id=%s history=%s (push queued until commit)",
             type_, user_id, notif_id, history)


def _is_within(txn, ancestor) -> bool:
    while txn is not None:
        if txn is ancestor:
            return True
        txn = txn.parent
    return False


@event.listens_for(Session, "after_commit")
def _release_queued_pushes(session: Session) -> None:
    # SQLAlchemy also fires after_commit when a SAVEPOINT is RELEASED —
    # at that point the data is not durable yet (the outer transaction
    # can still roll back), so releasing here would break the
    # "push only after commit" guarantee. Only the outermost commit counts.
    if session.in_nested_transaction():
        return
    entries = session.info.pop(_PENDING_KEY, None)
    if entries:
        _submit(_deliver_jobs, [job for _txn, job in entries])


@event.listens_for(Session, "after_soft_rollback")
def _discard_queued_pushes(session: Session, previous_transaction) -> None:
    entries = session.info.get(_PENDING_KEY)
    if not entries:
        return
    if previous_transaction.parent is None:        # the real transaction
        session.info.pop(_PENDING_KEY, None)
        dropped = len(entries)
    else:                                          # only a SAVEPOINT
        keep = [(t, j) for t, j in entries
                if not _is_within(t, previous_transaction)]
        dropped = len(entries) - len(keep)
        if keep:
            session.info[_PENDING_KEY] = keep
        else:
            session.info.pop(_PENDING_KEY, None)
    if dropped:
        log.info("notify: rollback — discarded %d queued push(es); "
                 "nothing was sent for them", dropped)


# ───────────────────────── worker pool ─────────────────────────────────

_executor = ThreadPoolExecutor(
    max_workers=int(os.getenv("PUSH_WORKERS", "4")),
    thread_name_prefix="gms-push",
)


def _submit(fn, *args) -> None:
    """Indirection so tests can run delivery inline/deterministically."""
    try:
        _executor.submit(fn, *args)
    except RuntimeError:  # interpreter shutting down
        log.warning("notify: worker pool unavailable — push not sent "
                    "(history rows are intact)")


def _deliver_jobs(jobs: list[PushJob]) -> None:
    for job in jobs:
        try:
            deliver_push(job)
        except Exception:  # never let one job kill the worker thread
            log.exception("notify: unexpected error delivering push to "
                          "user_id=%s", job.user_id)


# ───────────────────────── delivery (worker side) ──────────────────────

def build_message(target: _Target, job: PushJob):
    """Per-platform FCM message. THE web/Android split is deliberate:

    • web      → DATA-ONLY. Our service worker is the single place that
                 displays web notifications. If a `notification` block
                 were included, Firebase's SDK would ALSO auto-display
                 it → the duplicate-notification bug. title/body travel
                 in `data`.
    • android  → `notification` + `data`. The OS tray shows it when the
                 app is backgrounded/terminated; the app itself shows a
                 local popup when foregrounded.
    """
    from firebase_admin import messaging

    data = dict(job.data)
    data["title"] = job.title
    data["body"] = job.body

    if target.platform == "web":
        return messaging.Message(
            token=target.token,
            data=data,
            webpush=messaging.WebpushConfig(headers={"Urgency": "high"}),
        )
    return messaging.Message(
        token=target.token,
        notification=messaging.Notification(title=job.title, body=job.body),
        data=data,
        android=messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(
                channel_id=ANDROID_CHANNEL_ID,
                # One tray slot per conversation: a newer message REPLACES
                # that chat's notification instead of stacking; other chats
                # keep their own. The app's foreground popup uses the same
                # tag (id 0), so both paths update one notification.
                tag=(job.data.get("conversation_tag")
                     or (f"gms-n-{job.data['notif_id']}"
                         if job.data.get("notif_id") else None)),
                # Content hidden on the lock screen when the user's Android
                # setting hides sensitive notification content.
                visibility="private",
            ),
        ),
    )


@dataclass(frozen=True)
class _Result:
    success: bool
    exception: Exception | None = None


def _fcm_send_each(messages: list) -> list[_Result]:
    """Thin adapter over firebase_admin (also the test seam)."""
    from firebase_admin import messaging

    results: list[_Result] = []
    for i in range(0, len(messages), 500):          # FCM batch limit
        batch = messaging.send_each(messages[i:i + 500])
        results.extend(_Result(r.success, r.exception) for r in batch.responses)
    return results


def _classify(exc: Exception | None) -> str:
    """dead      → this token will never work again; deactivate it
       transient → worth retrying shortly
       permanent → log and move on (bad payload, auth, etc.)"""
    from firebase_admin import exceptions, messaging

    if isinstance(exc, (messaging.UnregisteredError,
                        messaging.SenderIdMismatchError)):
        return "dead"
    # UnknownError / ConnectionError / TimeoutError: what the SDK raises
    # for the WHOLE call when it cannot reach Google (verified against
    # the real SDK: "Unknown error while making remote service calls:
    # HTTPSConnectionPool…"). Nothing was sent, so a bounded retry is safe.
    if isinstance(exc, (exceptions.UnavailableError,
                        exceptions.InternalError,
                        exceptions.DeadlineExceededError,
                        exceptions.UnknownError,
                        messaging.QuotaExceededError,
                        ConnectionError,
                        TimeoutError)):
        return "transient"
    return "permanent"


def _load_targets(user_id: int, device_id: str | None = None) -> list[_Target]:
    db = _db_session.SessionLocal()
    try:
        q = (db.query(PushToken)
             .filter(PushToken.user_id == user_id,
                     PushToken.is_active == True))  # noqa: E712
        if device_id is not None:
            q = q.filter(PushToken.device_id == device_id)
        rows = q.all()
        return [_Target(r.id, r.token, r.platform) for r in rows]
    finally:
        db.close()


def _deactivate(token_ids: list[int]) -> None:
    if not token_ids:
        return
    db = _db_session.SessionLocal()
    try:
        db.execute(text("UPDATE user_push_tokens SET is_active = FALSE, "
                        "updated_at = CURRENT_TIMESTAMP "
                        "WHERE id = ANY(:ids)"), {"ids": list(token_ids)})
        db.commit()
    except Exception:
        db.rollback()
        log.exception("notify: could not deactivate dead token ids=%s",
                      token_ids)
    finally:
        db.close()


def deliver_push(job: PushJob, sleep=time.sleep) -> dict:
    """Sends one push to every active device of job.user_id.

    Tokens are read NOW (after the commit), not at queue time, so a
    device that switched accounts in between is never notified for the
    old account. Returns counters (used by tests and the summary log).
    """
    stats = {"tokens": 0, "sent": 0, "deactivated": 0, "failed": 0,
             "retried": 0}

    if not _firebase_ready:
        log.info("notify: FCM push skipped (Firebase not initialized) — "
                 "recipient user_id=%s, history record already saved",
                 job.user_id)
        return stats

    targets = _load_targets(job.user_id, job.device_id)
    stats["tokens"] = len(targets)
    log.info("notify: recipient user_id=%s — active push tokens found: %d "
             "(type=%s, queued %.0f ms ago)", job.user_id, len(targets),
             job.data.get("type", "?"), (time.monotonic() - job.queued_at) * 1000)
    if not targets:
        return stats

    dead_ids: list[int] = []
    pending = targets
    for attempt in range(MAX_SEND_ATTEMPTS):
        try:
            _t = time.monotonic()
            results = _fcm_send_each([build_message(t, job) for t in pending])
            log.info("notify: FCM call for user_id=%s type=%s took %.0f ms "
                     "(%.0f ms after commit)", job.user_id,
                     job.data.get("type", "?"), (time.monotonic() - _t) * 1000,
                     (time.monotonic() - job.queued_at) * 1000)
        except Exception as e:      # whole call failed (network/auth/etc.)
            log.warning("notify: FCM batch call failed for recipient "
                        "user_id=%s attempt=%d error=%s: %s", job.user_id,
                        attempt + 1, type(e).__name__, e)
            results = [_Result(False, e)] * len(pending)

        retry: list[_Target] = []
        for t, r in zip(pending, results):
            if r.success:
                stats["sent"] += 1
                log.info("notify: FCM send SUCCESS — recipient user_id=%s "
                         "platform=%s token_id=%s", job.user_id,
                         t.platform, t.id)
                continue
            kind = _classify(r.exception)
            if kind == "dead":
                dead_ids.append(t.id)
                log.info("notify: FCM token invalid/unregistered — "
                         "deactivating token_id=%s (recipient user_id=%s, "
                         "other devices unaffected)", t.id, job.user_id)
            elif kind == "transient" and attempt < MAX_SEND_ATTEMPTS - 1:
                retry.append(t)
            else:
                stats["failed"] += 1
                log.warning("notify: FCM send FAILED — recipient user_id=%s "
                            "platform=%s token_id=%s kind=%s error=%s: %s",
                            job.user_id, t.platform, t.id, kind,
                            type(r.exception).__name__, r.exception)
        if not retry:
            break
        stats["retried"] += len(retry)
        log.info("notify: retrying %d transient failure(s) for user_id=%s "
                 "(attempt %d/%d)", len(retry), job.user_id, attempt + 2,
                 MAX_SEND_ATTEMPTS)
        sleep(RETRY_BACKOFF_SECONDS[min(attempt, len(RETRY_BACKOFF_SECONDS) - 1)])
        pending = retry

    _deactivate(dead_ids)
    stats["deactivated"] = len(dead_ids)
    log.info("notify: recipient user_id=%s — FCM attempted for %d token(s), "
             "%d succeeded, %d invalid, %d failed", job.user_id,
             stats["tokens"], stats["sent"], stats["deactivated"],
             stats["failed"])
    return stats
