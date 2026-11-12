# /api/notifications — list (paginated), unread count, mark read,
# read-all, delete, and push-token registration for multi-device FCM.
import base64
import json
import logging
import random
import re
import time
from datetime import datetime

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sqlalchemy import and_, or_
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.database.session import get_db
from app.middleware.deps import get_current_user
from app.models.models import Notification, PushToken, User
from app.utils.helpers import row_to_dict
from app.services import notify as _notify

log = logging.getLogger("gms.notifications")

router = APIRouter(prefix="/api/notifications", tags=["Notifications"])

PAGE_SIZE = 20

# device_id is a random per-install id minted by the client (see
# frontend device_identity.dart). Strict format so it can't carry junk.
_REGISTER_ATTEMPTS = 6
_DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9_\-]{8,128}$")


def _encode_cursor(created_at, id_: int) -> str:
    raw = json.dumps({"t": str(created_at), "id": id_})
    return base64.urlsafe_b64encode(raw.encode()).decode()


def _decode_cursor(cursor: str):
    try:
        raw = base64.urlsafe_b64decode(cursor.encode()).decode()
        data = json.loads(raw)
        return data["t"], data["id"]
    except Exception:
        return None, None


# Types that never appear in the in-app Notifications page / bell count.
IN_APP_EXCLUDED = ("chat",)


@router.get("")
@router.get("/")
def list_notifications(cursor: str = None,
                       user: User = Depends(get_current_user),
                       db: Session = Depends(get_db)):
    """Cursor-based pagination, newest -> oldest, PAGE_SIZE (20) at a
    time. Not OFFSET-based on purpose — OFFSET gets slower and can
    skip/repeat rows as new notifications arrive between page loads;
    a cursor keyed on (created_at, id) doesn't have that problem and
    stays correct even if new rows are inserted mid-scroll.
    """
    # Business/system events only. Chat alerts are push-only (V16); old
    # chat rows written before that are hidden here too.
    q = db.query(Notification).filter(Notification.user_id == user.id,
                                      Notification.type.notin_(IN_APP_EXCLUDED))

    if cursor:
        c_created_at, c_id = _decode_cursor(cursor)
        if c_created_at is not None:
            q = q.filter(
                or_(
                    Notification.created_at < c_created_at,
                    and_(Notification.created_at == c_created_at,
                         Notification.id < c_id),
                )
            )

    rows = (q.order_by(Notification.created_at.desc(), Notification.id.desc())
            .limit(PAGE_SIZE + 1).all())

    has_more = len(rows) > PAGE_SIZE
    rows = rows[:PAGE_SIZE]
    next_cursor = (_encode_cursor(rows[-1].created_at, rows[-1].id)
                   if rows and has_more else None)

    return {
        "success": True,
        "notifications": [row_to_dict(n) for n in rows],
        "next_cursor": next_cursor,
        "has_more": has_more,
    }


@router.get("/unread-count")
def unread_count(user: User = Depends(get_current_user),
                 db: Session = Depends(get_db)):
    count = (db.query(Notification)
             .filter(Notification.user_id == user.id,
                     Notification.is_read == False,  # noqa: E712
                     Notification.type.notin_(IN_APP_EXCLUDED))
             .count())
    return {"success": True, "unread": count}


@router.put("/read-all")
def read_all(user: User = Depends(get_current_user),
             db: Session = Depends(get_db)):
    db.query(Notification).filter(
        Notification.user_id == user.id).update({"is_read": True})
    db.commit()
    return {"success": True}


# ─────────────────────────────────────────────
# Push token lifecycle — one row per device. Called on login (and
# whenever Firebase reports a token refresh) to register/update,
# and on logout to deactivate just that one device.
#
# Registered BEFORE /{notif_id} below on purpose — FastAPI matches
# routes in registration order, and a literal path like /push-token
# needs to come before a variable one like /{notif_id}, or the
# variable route greedily catches it first (this exact bug shipped
# once already: DELETE /push-token was being caught by DELETE
# /{notif_id}, which then failed trying to parse "push-token" as an
# integer id).
# ─────────────────────────────────────────────
@router.post("/push-token")
def register_push_token(body: dict, user: User = Depends(get_current_user),
                        db: Session = Depends(get_db)):
    """Register/refresh THIS device's token for the signed-in user.

    Guarantees (the multi-user / multi-device contract):
      • one row per physical token (token is UNIQUE) — re-registering
        the same token is a harmless upsert;
      • when a device_id is supplied, at most ONE active token per
        (user, device) — a refreshed token deactivates the old one, so
        the device can't receive doubled pushes;
      • a device now belongs to whoever registered last: any OTHER
        account's active tokens on this same device_id are deactivated,
        so after an account switch the previous user's notifications
        stop reaching this device immediately, even if their logout
        call never made it to the server;
      • other devices of the same user are untouched.
    """
    token = (body.get("token") or "").strip()
    platform = (body.get("platform") or "android").strip().lower()
    device_id = (body.get("device_id") or "").strip() or None

    if not token:
        return JSONResponse(status_code=400, content={
            "success": False, "message": "token is required."})
    if platform not in ("android", "ios", "web"):
        return JSONResponse(status_code=400, content={
            "success": False, "message": "platform must be android, ios, or web."})
    if device_id and not _DEVICE_ID_RE.match(device_id):
        return JSONResponse(status_code=400, content={
            "success": False,
            "message": "device_id must be 8-128 chars of letters, digits, - or _."})

    # Registrations for the same device can race (token refresh vs.
    # login sync vs. a retry). The partial unique index makes a loser
    # fail with IntegrityError — and every such failure means ANOTHER
    # registration just committed, so retrying converges quickly. A few
    # attempts with a tiny jitter comfortably exceeds the realistic
    # concurrency (2-3) while staying bounded.
    for attempt in range(_REGISTER_ATTEMPTS):
        try:
            _upsert_push_token(db, user.id, token, platform, device_id)
            db.commit()
            break
        except IntegrityError:
            db.rollback()
            if attempt == _REGISTER_ATTEMPTS - 1:
                raise
            time.sleep(random.uniform(0.005, 0.03))
    return {"success": True, "device_id": device_id}


def _upsert_push_token(db: Session, user_id: int, token: str, platform: str,
                       device_id: str | None) -> None:
    now = datetime.now()

    if device_id:
        # Order matters: deactivate competing rows BEFORE (re)activating
        # this one, or the partial unique index would reject it.
        # 1) another account's active tokens on this same device
        swept_other = (db.query(PushToken)
                       .filter(PushToken.device_id == device_id,
                               PushToken.user_id != user_id,
                               PushToken.is_active == True)  # noqa: E712
                       .update({"is_active": False, "updated_at": now},
                               synchronize_session=False))
        # 2) this user's older token(s) on this same device (token refresh)
        swept_old = (db.query(PushToken)
                     .filter(PushToken.user_id == user_id,
                             PushToken.device_id == device_id,
                             PushToken.token != token,
                             PushToken.is_active == True)  # noqa: E712
                     .update({"is_active": False, "updated_at": now},
                             synchronize_session=False))
        if swept_other or swept_old:
            log.info("push-token: device swept — other-account tokens "
                     "deactivated=%d, stale same-user tokens deactivated=%d "
                     "(user_id=%s)", swept_other, swept_old, user_id)

    existing = db.query(PushToken).filter(PushToken.token == token).first()
    if existing:
        # Same physical token, possibly a different account now logged in
        # on this device — reassign rather than duplicate (token UNIQUE).
        existing.user_id = user_id
        existing.platform = platform
        if device_id:
            existing.device_id = device_id
        existing.is_active = True
        existing.updated_at = now
        existing.last_seen_at = now
    else:
        db.add(PushToken(user_id=user_id, token=token, platform=platform,
                         device_id=device_id, is_active=True))


@router.delete("/push-token")
def remove_push_token(body: dict = None, token: str = None,
                      device_id: str = None,
                      user: User = Depends(get_current_user),
                      db: Session = Depends(get_db)):
    # Deactivates only THIS device for THIS user (logout on one device
    # must never affect the person's other active sessions/devices).
    # Matches by token and/or device_id so logout still cleans up even
    # if the client's cached token string was lost.
    tok = token or (body or {}).get("token")
    dev = device_id or (body or {}).get("device_id")
    if not tok and not dev:
        return JSONResponse(status_code=400, content={
            "success": False, "message": "token or device_id is required."})

    conds = []
    if tok:
        conds.append(PushToken.token == tok)
    if dev:
        conds.append(PushToken.device_id == dev)
    n = (db.query(PushToken)
         .filter(PushToken.user_id == user.id,
                 PushToken.is_active == True,  # noqa: E712
                 or_(*conds))
         .update({"is_active": False, "updated_at": datetime.now()},
                 synchronize_session=False))
    db.commit()
    return {"success": True, "deactivated": n}


@router.put("/{notif_id}/read")
def read_one(notif_id: int, user: User = Depends(get_current_user),
             db: Session = Depends(get_db)):
    n = db.get(Notification, notif_id)
    if not n or n.user_id != user.id:
        return JSONResponse(status_code=404, content={
            "success": False, "message": "Notification not found."})
    n.is_read = True
    db.commit()
    return {"success": True}


@router.delete("/{notif_id}")
def delete_one(notif_id: int, user: User = Depends(get_current_user),
               db: Session = Depends(get_db)):
    n = db.get(Notification, notif_id)
    if not n or n.user_id != user.id:
        return JSONResponse(status_code=404, content={
            "success": False, "message": "Notification not found."})
    db.delete(n)
    db.commit()
    return {"success": True}


# ── Login welcome push ─────────────────────────────────────────────────
WELCOME_TITLE = "Welcome back to GMS"
WELCOME_BODY = "You're signed in and ready to find a service."
_WELCOME_WINDOW_S = 120
_recent_welcomes: dict[tuple[int, str], float] = {}


@router.post("/welcome")
def send_login_welcome(body: dict, user: User = Depends(get_current_user),
                       db: Session = Depends(get_db)):
    """Called by the app ONLY after an interactive sign-in, once this
    device's push token is registered. Pushes to that device alone (never
    the user's other phones/browsers) and never twice within two minutes
    for the same device (a retried call is harmless). No history row."""
    device_id = str((body or {}).get("device_id") or "").strip()
    if not device_id or len(device_id) > 200:
        return JSONResponse(status_code=400, content={
            "success": False, "message": "device_id is required."})
    has_token = db.query(PushToken.id).filter(
        PushToken.user_id == user.id, PushToken.device_id == device_id,
        PushToken.is_active == True).first() is not None  # noqa: E712
    if not has_token:
        return {"success": True, "sent": False, "reason": "no_active_token"}
    now = time.monotonic()
    key = (user.id, device_id)
    if now - _recent_welcomes.get(key, -1e9) < _WELCOME_WINDOW_S:
        return {"success": True, "sent": False, "reason": "already_sent"}
    _recent_welcomes[key] = now
    _notify.push_to_device(user.id, device_id, WELCOME_TITLE, WELCOME_BODY,
                           data={"type": "welcome", "screen": "home",
                                 "notif_id": f"welcome-{user.id}-{int(time.time())}"})
    return {"success": True, "sent": True}


# ── Booking events: unseen count + "New" markers ───────────────────────
# One Notification row is written per real, committed booking event
# (status-guarded + row-locked in booking_engine), so duplicate pushes or
# retries never add rows → never inflate the count. Unseen = unread.
BOOKING_EVENT_TYPES = ("booking_new", "booking_status", "payment")


def _booking_unread(db: Session, user_id: int):
    return db.query(Notification).filter(
        Notification.user_id == user_id,
        Notification.is_read == False,  # noqa: E712
        Notification.type.in_(BOOKING_EVENT_TYPES),
        Notification.ref_id.isnot(None))


@router.get("/booking-unseen")
def booking_unseen(user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)):
    """Bookings tab badge + per-booking "New" markers, the same on every
    device (server state). Nothing here marks anything seen."""
    by_booking: dict[str, int] = {}
    total = 0
    for (ref_id,) in _booking_unread(db, user.id).with_entities(Notification.ref_id):
        by_booking[str(ref_id)] = by_booking.get(str(ref_id), 0) + 1
        total += 1
    # The bell's total unread count rides along, so the app's 3-second
    # poll is ONE request (it used to be two: this + /unread-count).
    unread_total = db.query(Notification).filter(
        Notification.user_id == user.id,
        Notification.is_read == False,  # noqa: E712
        Notification.type.notin_(IN_APP_EXCLUDED)).count()
    return {"success": True, "count": total, "by_booking": by_booking,
            "unread_total": unread_total}


@router.put("/booking/{booking_id}/seen")
def booking_seen(booking_id: int, user: User = Depends(get_current_user),
                 db: Session = Depends(get_db)):
    """The user opened THIS booking's details in the app: its unseen
    events are now seen (once — repeating changes nothing). Other
    bookings and pending actions are untouched."""
    n = _booking_unread(db, user.id).filter(
        Notification.ref_id == booking_id).update(
        {"is_read": True}, synchronize_session=False)
    if n:
        db.commit()
    return {"success": True, "updated": n}
