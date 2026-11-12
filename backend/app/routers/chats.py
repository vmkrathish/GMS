# /api/chats — conversations (latest per partner + unread counts),
# thread (marks read), send. Same shapes as legacy.
import json
import logging
import time
from datetime import datetime

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from sqlalchemy import func, text
from sqlalchemy.orm import Session

from app.database.session import get_db
from app.middleware.deps import get_current_user
from app.models.models import Message, User
from app.services import idempotency as idem
from app.services.notify import notify
from app.utils.helpers import jsonable

_log = logging.getLogger("gms.chat")
router = APIRouter(prefix="/api/chats", tags=["Chats"])


def _fail(status: int, message: str):
    return JSONResponse(status_code=status,
                        content={"success": False, "message": message})


@router.get("")
@router.get("/")
def conversations(user: User = Depends(get_current_user),
                  db: Session = Depends(get_db)):
    # Delivered = the recipient's client is confirmed online right
    # now (this endpoint is polled every ~20s by the app the whole
    # time it's running — see ChatBadgeService — not just when a
    # specific thread is open). This is the correct signal for the
    # grey double-tick: "their device received it", distinct from
    # "they've actually read it" (blue tick, set in thread() below).
    newly_delivered = db.query(Message).filter(
        Message.receiver_id == user.id,
        Message.delivered_at.is_(None),
    ).update({"delivered_at": datetime.now()})
    # Most polls (every ~20s) find nothing new to mark — skip the
    # COMMIT round trip to the database in that case.
    if newly_delivered:
        db.commit()

    rows = db.execute(text("""
        SELECT
          partner.id         AS partner_id,
          partner.name       AS partner_name,
          partner.avatar_url AS partner_avatar,
          partner.last_seen_at AS partner_last_seen,
          m.body             AS last_message,
          m.created_at       AS last_message_at,
          (m.sender_id = :me) AS last_from_me,
          (SELECT COUNT(*) FROM messages um
             WHERE um.sender_id = partner.id AND um.receiver_id = :me AND um.is_read = FALSE
          ) AS unread_count
        FROM messages m
        JOIN (
          SELECT MAX(id) AS max_id
          FROM messages
          WHERE sender_id = :me OR receiver_id = :me
          GROUP BY CASE WHEN sender_id = :me THEN receiver_id ELSE sender_id END
        ) latest ON latest.max_id = m.id
        JOIN users partner
          ON partner.id = CASE WHEN m.sender_id = :me THEN m.receiver_id ELSE m.sender_id END
        ORDER BY m.created_at DESC
    """), {"me": user.id}).mappings().all()
    return {"success": True,
            "conversations": [{k: jsonable(v) for k, v in r.items()} for r in rows]}


@router.get("/{user_id}")
def thread(user_id: int, limit: int = 50,
           user: User = Depends(get_current_user),
           db: Session = Depends(get_db)):
    limit = min(limit, 200)
    rows = db.execute(text("""
        SELECT id, sender_id, receiver_id, body, is_read, read_at,
               delivered_at, created_at
        FROM messages
        WHERE (sender_id = :me AND receiver_id = :other)
           OR (sender_id = :other AND receiver_id = :me)
        ORDER BY id DESC LIMIT :limit
    """), {"me": user.id, "other": user_id, "limit": limit}).mappings().all()

    # Opening the thread confirms both delivered AND read in one
    # step — covers the case where this is the very first time the
    # recipient's client has talked to the backend since the message
    # arrived (e.g. opening the app directly into this thread from a
    # push notification, skipping the conversations-list poll
    # entirely).
    db.query(Message).filter(
        Message.sender_id == user_id,
        Message.receiver_id == user.id,
        Message.is_read == False,  # noqa: E712
    ).update({"is_read": True, "read_at": datetime.now(),
              "delivered_at": func.coalesce(Message.delivered_at, datetime.now())})
    db.commit()

    partner = db.get(User, user_id)
    return {
        "success": True,
        "partner": {"id": partner.id, "name": partner.name,
                    "avatar_url": partner.avatar_url,
                    "last_seen_at": jsonable(partner.last_seen_at)
                    if partner.last_seen_at else None}
        if partner else None,
        "messages": [{k: jsonable(v) for k, v in r.items()}
                     for r in reversed(rows)],
    }


PREVIEW_MAX = 160


def message_preview(text_: str) -> str:
    t = " ".join((text_ or "").split())
    return t if len(t) <= PREVIEW_MAX else t[:PREVIEW_MAX - 1].rstrip() + "…"


RECENT_LINES = 5          # lines in the expanded Android notification
RECENT_LINE_MAX = 120     # keeps the FCM data payload well under 4 KB


def recent_unread_lines(db: Session, sender_id: int, receiver_id: int) -> str:
    """JSON list (oldest first) of the newest unread messages in this
    conversation, for a WhatsApp-style expanded notification. Only what
    the recipient hasn't read yet — opening the chat starts a fresh one."""
    rows = (db.query(Message.body, Message.created_at)
            .filter(Message.sender_id == sender_id,
                    Message.receiver_id == receiver_id,
                    Message.is_read == False)  # noqa: E712
            .order_by(Message.id.desc()).limit(RECENT_LINES).all())
    lines = []
    for body_, created in reversed(rows):
        t = " ".join((body_ or "").split())
        if len(t) > RECENT_LINE_MAX:
            t = t[:RECENT_LINE_MAX - 1].rstrip() + "…"
        lines.append({"t": t, "ts": created.isoformat() if created else ""})
    return json.dumps(lines, ensure_ascii=False, separators=(",", ":"))


def conversation_tag(partner_id: int) -> str:
    """Same string the Flutter app uses (chat_push.dart)."""
    return f"gms-chat-{partner_id}"


@router.post("/receipts/delivered")
def delivered_receipt(body: dict, user: User = Depends(get_current_user),
                      db: Session = Depends(get_db)):
    """The recipient's DEVICE confirms it received these messages (sent
    by the app's FCM handler, foreground or background) → two grey ticks
    for the sender. Only the recipient's own messages are touched, only
    the first acknowledgement sets the time, so retries are harmless.
    "FCM accepted the push" is never treated as delivered."""
    ids = body.get("message_ids") if isinstance(body, dict) else None
    if not isinstance(ids, list) or not 1 <= len(ids) <= 100:
        return _fail(400, "message_ids must be a list of 1 to 100 ids.")
    try:
        ids = sorted({int(i) for i in ids})
    except (TypeError, ValueError):
        return _fail(400, "message_ids must be integers.")
    updated = db.query(Message).filter(
        Message.id.in_(ids),
        Message.receiver_id == user.id,
        Message.delivered_at.is_(None),
    ).update({"delivered_at": datetime.now()}, synchronize_session=False)
    if updated:
        db.commit()
    return {"success": True, "updated": updated}


@router.post("/{user_id}")
def send(user_id: int, body: dict, request: Request,
         user: User = Depends(get_current_user),
         db: Session = Depends(get_db)):
    _t0 = time.perf_counter()
    content = (body.get("body") or "").strip()
    if not user_id or user_id == user.id:
        return _fail(400, "Invalid recipient.")
    if not content or len(content) > 4000:
        return _fail(400, "Message cannot be empty.")

    other = db.get(User, user_id)
    if not other or not other.is_active:
        return _fail(404, "User not found.")

    # A retried request (same Idempotency-Key) returns the first one's
    # stored response — no second message, no second push.
    replay, idem_row = idem.claim(db, user.id, f"chat.send.{user_id}",
                                  idem.key_from_request(request))
    if replay is not None:
        return replay

    msg = Message(sender_id=user.id, receiver_id=user_id, body=content)
    db.add(msg)
    db.flush()   # msg.id is needed in the push (delivery receipt + tag)

    # Notify the recipient — never the sender about their own message.
    # WhatsApp-style: title = sender, body = the message text (preview,
    # trimmed). Whether that text is visible on the LOCK SCREEN is left
    # to Android's own setting (the notification is "private" — the OS
    # hides its content when the user chose to hide sensitive content).
    # "partner_id" here IS the sender, from the recipient's point of
    # view — this app identifies a conversation by the other
    # participant's user_id (see the /api/chats/{user_id} route below).
    # conversation_tag gives every chat ONE notification slot on Android
    # (system tray and the app's own foreground popup use the same tag),
    # so new messages update that chat's notification and different
    # chats stay separate.
    # history=False: chat alerts go to the phone/browser only — the
    # in-app Notifications page is for bookings, payments and service news.
    notify(db, user_id, user.name or "New message", message_preview(content),
           type_="chat", ref_id=user.id, history=False,
           data={"screen": "chat", "partner_id": user.id,
                 "message_id": msg.id, "notif_id": f"chat-{msg.id}",
                 "conversation_tag": conversation_tag(user.id),
                 "recent": recent_unread_lines(db, user.id, user_id),
                 # Shown in the notification's circle; the app falls back
                 # to the initial when empty or it can't be downloaded.
                 "sender_avatar": user.avatar_url or ""})

    # notify() above only QUEUED the push. Flush to materialise the
    # server-side created_at, store the idempotent response in this same
    # transaction, then commit — the commit is what releases the push
    # (and a rollback discards it). See services/notify.py.
    db.flush()
    db.refresh(msg)
    out = {
        "success": True,
        "message": {"id": msg.id, "sender_id": msg.sender_id,
                    "receiver_id": msg.receiver_id, "body": msg.body,
                    "is_read": 0, "delivered_at": None,
                    "created_at": jsonable(msg.created_at)},
    }
    idem.complete(idem_row, 201, out)
    db.commit()
    # Privacy-safe timing (ids only — never the text or the key itself).
    _log.info("chat.send saved msg=%s from=%s to=%s keyed=%s in %.0f ms",
              msg.id, user.id, user_id, bool(idem.key_from_request(request)),
              (time.perf_counter() - _t0) * 1000)
    return JSONResponse(status_code=201, content=out)
