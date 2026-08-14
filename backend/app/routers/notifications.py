# /api/notifications — list (paginated), unread count, mark read,
# read-all, delete, and push-token registration for multi-device FCM.
import base64
import json
import logging

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sqlalchemy import and_, or_
from sqlalchemy.orm import Session

from app.database.session import get_db
from app.middleware.deps import get_current_user
from app.models.models import Notification, PushToken, User
from app.utils.helpers import row_to_dict

log = logging.getLogger("gms.notifications")

router = APIRouter(prefix="/api/notifications", tags=["Notifications"])

PAGE_SIZE = 20


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
    q = db.query(Notification).filter(Notification.user_id == user.id)

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
                     Notification.is_read == False)  # noqa: E712
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
    token = (body.get("token") or "").strip()
    platform = (body.get("platform") or "android").strip().lower()
    device_id = (body.get("device_id") or "").strip() or None

    if not token:
        return JSONResponse(status_code=400, content={
            "success": False, "message": "token is required."})
    if platform not in ("android", "ios", "web"):
        return JSONResponse(status_code=400, content={
            "success": False, "message": "platform must be android, ios, or web."})

    from datetime import datetime
    existing = db.query(PushToken).filter(PushToken.token == token).first()
    if existing:
        # Same physical token, possibly a different account now
        # logged in on this device (e.g. after logout/login as
        # someone else) — reassign it rather than creating a
        # duplicate, since `token` is UNIQUE.
        existing.user_id = user.id
        existing.platform = platform
        existing.device_id = device_id
        existing.is_active = True
        existing.updated_at = datetime.now()
        existing.last_seen_at = datetime.now()
    else:
        db.add(PushToken(user_id=user.id, token=token, platform=platform,
                         device_id=device_id, is_active=True))
    db.commit()
    return {"success": True}


@router.delete("/push-token")
def remove_push_token(body: dict = None, token: str = None,
                      user: User = Depends(get_current_user),
                      db: Session = Depends(get_db)):
    # Deactivates only THIS device's token (logout on one device must
    # never affect the person's other active sessions/devices).
    tok = token or (body or {}).get("token")
    if not tok:
        return JSONResponse(status_code=400, content={
            "success": False, "message": "token is required."})
    pt = (db.query(PushToken)
          .filter(PushToken.token == tok, PushToken.user_id == user.id)
          .first())
    if pt:
        pt.is_active = False
        db.commit()
    return {"success": True}


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
