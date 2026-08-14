# ─────────────────────────────────────────────
# /api/bookings — create, lists (with avatars), detail,
# workflow actions, timeline. Shapes match legacy exactly.
# ─────────────────────────────────────────────
from datetime import datetime

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.database.session import get_db
from app.middleware.deps import get_current_user
from app.models.models import Booking, Service, User
from app.services.booking_engine import (
    WorkflowError,
    apply_expiry,
    execute_action,
    log_event,
)
from app.services.notify import notify
from app.utils.helpers import jsonable

router = APIRouter(prefix="/api/bookings", tags=["Bookings"])


def _fail(status: int, message: str):
    return JSONResponse(status_code=status,
                        content={"success": False, "message": message})


LIST_SQL = """
    SELECT
      b.*,
      s.title  AS service_title,
      s.price  AS service_price,
      s.price_unit,
      sc.name  AS category_name,
      sc.emoji AS category_emoji,
      cu.name  AS customer_name,
      cu.avatar_url AS customer_avatar,
      pu.name  AS provider_name,
      pu.avatar_url AS provider_avatar,
      pu.latitude  AS provider_lat,
      pu.longitude AS provider_lng
    FROM bookings b
    JOIN services s  ON b.service_id = s.id
    JOIN service_categories sc ON s.category_id = sc.id
    JOIN users cu ON b.customer_id = cu.id
    JOIN users pu ON b.provider_id = pu.id
"""


def _rows(db: Session, where: str, params: dict):
    rows = db.execute(
        text(LIST_SQL + where + " ORDER BY b.updated_at DESC, b.id DESC"),
        params).mappings().all()
    return [{k: jsonable(v) for k, v in r.items()} for r in rows]


@router.post("")
@router.post("/")
def create_booking(body: dict, user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)):
    service_id = body.get("service_id")
    if not service_id:
        return _fail(400, "service_id is required.")

    svc = db.get(Service, int(service_id))
    if not svc or not svc.is_active:
        return _fail(404, "Service not found.")
    if svc.provider_id == user.id:
        return _fail(400, "You cannot book your own service.")

    scheduled = body.get("scheduled_at")
    lat = body.get("customer_lat")
    lng = body.get("customer_lng")
    booking = Booking(
        customer_id=user.id,
        provider_id=svc.provider_id,
        service_id=svc.id,
        status="pending",
        scheduled_at=datetime.fromisoformat(str(scheduled).replace("Z", "+00:00")).replace(tzinfo=None)
        if scheduled else datetime.now(),
        address=(body.get("address") or "").strip() or None,
        customer_lat=float(lat) if lat is not None else None,
        customer_lng=float(lng) if lng is not None else None,
        notes=(body.get("notes") or "").strip() or None,
    )
    db.add(booking)
    db.flush()

    log_event(db, booking.id, user.id, "customer", "requested",
              proposed_time=booking.scheduled_at)
    notify(db, svc.provider_id, "New Booking Request",
           f"{user.name} requested your {svc.title} service.", "booking_new",
           booking.id, data={"screen": "booking", "booking_id": booking.id})
    db.commit()

    return JSONResponse(status_code=201, content={
        "success": True,
        "booking": {"id": booking.id, "status": booking.status},
        "message": "Booking request sent.",
    })


@router.get("/mine")
def my_bookings(user: User = Depends(get_current_user),
                db: Session = Depends(get_db)):
    return {"success": True,
            "bookings": _rows(db, " WHERE b.customer_id = :uid", {"uid": user.id})}


@router.get("/received")
def received_bookings(user: User = Depends(get_current_user),
                      db: Session = Depends(get_db)):
    # Dual-role: any user with listings can receive bookings
    return {"success": True,
            "bookings": _rows(db, " WHERE b.provider_id = :uid", {"uid": user.id})}


@router.get("/{booking_id}")
def booking_detail(booking_id: int, user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)):
    booking = db.get(Booking, booking_id)
    if not booking:
        return _fail(404, "Booking not found.")
    if user.id not in (booking.customer_id, booking.provider_id):
        return _fail(403, "Access denied.")
    apply_expiry(db, booking)
    rows = _rows(db, " WHERE b.id = :bid", {"bid": booking_id})
    return {"success": True, "booking": rows[0] if rows else None}


@router.put("/{booking_id}/action")
def booking_action(booking_id: int, body: dict,
                   user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)):
    booking = db.get(Booking, booking_id)
    if not booking:
        return _fail(404, "Booking not found.")
    try:
        booking = execute_action(db, booking, user, body)
    except WorkflowError as e:
        return _fail(e.status_code, e.message)
    rows = _rows(db, " WHERE b.id = :bid", {"bid": booking_id})
    return {"success": True, "booking": rows[0] if rows else None}


@router.put("/{booking_id}/status")
def booking_status_compat(booking_id: int, body: dict,
                          user: User = Depends(get_current_user),
                          db: Session = Depends(get_db)):
    # Back-compat shim: old status names map to workflow actions.
    mapping = {"accepted": "accept", "rejected": "reject",
               "in_progress": "start", "completed": "complete",
               "cancelled": "cancel"}
    body["action"] = mapping.get(body.get("status"), body.get("status") or body.get("action"))
    return booking_action(booking_id, body, user, db)


@router.get("/{booking_id}/events")
def booking_events(booking_id: int, user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)):
    booking = db.get(Booking, booking_id)
    if not booking:
        return _fail(404, "Booking not found.")
    if user.id not in (booking.customer_id, booking.provider_id):
        return _fail(403, "Access denied.")
    rows = db.execute(text("""
        SELECT e.*, u.name AS actor_name
        FROM booking_events e JOIN users u ON u.id = e.actor_id
        WHERE e.booking_id = :bid ORDER BY e.id ASC
    """), {"bid": booking_id}).mappings().all()
    return {"success": True,
            "events": [{k: jsonable(v) for k, v in r.items()} for r in rows]}
