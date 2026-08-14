# /api/chats — conversations (latest per partner + unread counts),
# thread (marks read), send. Same shapes as legacy.
from datetime import datetime

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sqlalchemy import func, text
from sqlalchemy.orm import Session

from app.database.session import get_db
from app.middleware.deps import get_current_user
from app.models.models import Message, User
from app.services.notify import notify
from app.utils.helpers import jsonable

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
    db.query(Message).filter(
        Message.receiver_id == user.id,
        Message.delivered_at.is_(None),
    ).update({"delivered_at": datetime.now()})
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


@router.post("/{user_id}")
def send(user_id: int, body: dict,
         user: User = Depends(get_current_user),
         db: Session = Depends(get_db)):
    content = (body.get("body") or "").strip()
    if not user_id or user_id == user.id:
        return _fail(400, "Invalid recipient.")
    if not content or len(content) > 4000:
        return _fail(400, "Message cannot be empty.")

    other = db.get(User, user_id)
    if not other or not other.is_active:
        return _fail(404, "User not found.")

    msg = Message(sender_id=user.id, receiver_id=user_id, body=content)
    db.add(msg)

    # Notify the recipient — never the sender about their own
    # message. Body is a preview, not the full message (matches
    # the spirit of "Rathish sent you a message" from the spec,
    # rather than exposing full message content in a push banner).
    # "partner_id" here IS the sender, from the recipient's point of
    # view — this app identifies a conversation by the other
    # participant's user_id (see the /api/chats/{user_id} route
    # below), there's no separate chat_id concept to conflate this
    # with.
    notify(db, user_id, "New Message", f"{user.name} sent you a message.",
           type_="chat", ref_id=user.id,
           data={"screen": "chat", "partner_id": user.id})

    db.commit()
    db.refresh(msg)
    return JSONResponse(status_code=201, content={
        "success": True,
        "message": {"id": msg.id, "sender_id": msg.sender_id,
                    "receiver_id": msg.receiver_id, "body": msg.body,
                    "is_read": 0, "delivered_at": None,
                    "created_at": jsonable(msg.created_at)},
    })
