# ─────────────────────────────────────────────
# app/services/booking_engine.py
#
# THE TWO-STEP VERIFICATION WORKFLOW ENGINE (ported 1:1
# from the legacy backend, then cleaned up):
#
#  pending ──accept(+advance)──▶ awaiting_advance ──pay_advance──▶ confirmed
#     │                              │
#     ├─reject(reason!)─▶ rejected   └─(deadline passes)─▶ expired
#     ├─reschedule ⇄ counter_proposal (UNLIMITED negotiation loop)
#     └─cancel─▶ cancelled_by_customer / cancelled_by_provider
#  confirmed ─start─▶ in_progress(Visiting) ─complete─▶ completed
#
#  Provider approval alone NEVER confirms — the customer's
#  advance payment is the second verification step.
# ─────────────────────────────────────────────
from datetime import datetime

from sqlalchemy.orm import Session

from app.models.models import Booking, BookingEvent, Service
from app.services.notify import notify
from app.services.pricing import get_config_decimal

ACTIVE_STATES = [
    "pending", "awaiting_advance", "confirmed", "in_progress",
    "reschedule_by_provider", "reschedule_by_customer",
]

# action → (allowed role, valid source statuses)
ACTIONS: dict[str, dict] = {
    "accept":           {"role": "provider", "from": ["pending", "reschedule_by_customer"]},
    "reject":           {"role": "provider", "from": ["pending", "reschedule_by_customer"]},
    "reschedule":       {"role": "provider", "from": ["pending", "awaiting_advance", "confirmed", "reschedule_by_customer"]},
    "accept_proposal":  {"role": "customer", "from": ["reschedule_by_provider"]},
    "counter_proposal": {"role": "customer", "from": ["reschedule_by_provider", "pending", "awaiting_advance", "confirmed"]},
    "pay_advance":      {"role": "customer", "from": ["awaiting_advance"]},
    "cancel":           {"role": "any",      "from": ACTIVE_STATES},
    "start":            {"role": "provider", "from": ["confirmed"]},
    "complete":         {"role": "provider", "from": ["in_progress"]},
}


class WorkflowError(Exception):
    def __init__(self, status_code: int, message: str):
        self.status_code = status_code
        self.message = message


def log_event(db: Session, booking_id: int, actor_id: int, actor_role: str,
              action: str, reason=None, proposed_time=None, amount=None):
    db.add(BookingEvent(
        booking_id=booking_id, actor_id=actor_id, actor_role=actor_role,
        action=action, reason=reason, proposed_time=proposed_time, amount=amount,
    ))


def apply_expiry(db: Session, booking: Booking) -> Booking:
    """Lazy expiry: awaiting_advance past its deadline becomes expired."""
    if (booking.status == "awaiting_advance"
            and booking.payment_deadline
            and booking.payment_deadline < datetime.now()):
        booking.status = "expired"
        booking.cancel_reason = "Advance not paid before deadline"
        log_event(db, booking.id, booking.customer_id, "system", "expired",
                  reason="Advance not paid before deadline")
        db.commit()
    return booking


def _parse_dt(value) -> datetime:
    if isinstance(value, datetime):
        return value
    return datetime.fromisoformat(str(value).replace("Z", "+00:00")).replace(tzinfo=None)


def execute_action(db: Session, booking: Booking, user, payload: dict) -> Booking:
    """Validate + apply one workflow action. Raises WorkflowError on bad input."""
    action = payload.get("action")
    reason = (payload.get("reason") or "").strip() or None
    proposed_time = payload.get("proposed_time")
    advance_amount = payload.get("advance_amount")
    payment_deadline = payload.get("payment_deadline")

    booking = apply_expiry(db, booking)

    # Dual-role: your role in THIS booking comes from the booking itself
    is_provider = booking.provider_id == user.id
    is_customer = booking.customer_id == user.id
    if not is_provider and not is_customer:
        raise WorkflowError(403, "Access denied.")
    role = "provider" if is_provider else "customer"

    spec = ACTIONS.get(action)
    if not spec:
        raise WorkflowError(400, f'Unknown action "{action}".')
    if spec["role"] != "any" and spec["role"] != role:
        raise WorkflowError(403, f'Only the {spec["role"]} can {action}.')
    if booking.status not in spec["from"]:
        raise WorkflowError(400, f'Cannot {action} while booking is "{booking.status}".')

    event = action
    notif: dict | None = None
    other_id = booking.customer_id if is_provider else booking.provider_id
    me = user.name or ("Provider" if is_provider else "Customer")

    if action == "accept":
        if booking.status == "reschedule_by_customer" and booking.proposed_time:
            booking.scheduled_at = booking.proposed_time
            booking.proposed_time = None
        # Platform-controlled advance — no longer a manually-entered
        # amount. Always 25% of the service's own listed price,
        # rounded to the nearest rupee. The client's advance_amount
        # (if it sends one at all) is deliberately ignored here,
        # same principle as service pricing itself: the platform
        # calculates it, the provider doesn't type in a number.
        service = db.get(Service, booking.service_id)
        service_price = float(service.price) if service and service.price else 0.0
        advance_pct = float(get_config_decimal(db, "advance_percent", "25"))
        amt = round(service_price * advance_pct / 100, 2)
        booking.status = "awaiting_advance"
        booking.advance_amount = amt
        if payment_deadline:
            booking.payment_deadline = _parse_dt(payment_deadline)
        event = "advance_requested"
        notif = dict(to=booking.customer_id, type="payment",
                     title="Advance payment requested",
                     body=f"{me} accepted! Pay ₹{amt:g} advance "
                     f"({advance_pct:g}% of the service price) to confirm your booking.")

    elif action == "reject":
        if not reason:
            raise WorkflowError(400, "A rejection reason is required.")
        booking.status = "rejected"
        booking.cancel_reason = reason
        notif = dict(to=booking.customer_id, type="booking_status",
                     title="Booking rejected", body=f"{me} rejected: {reason}")

    elif action == "reschedule":
        if not proposed_time:
            raise WorkflowError(400, "proposed_time is required.")
        if not reason:
            raise WorkflowError(400, "A reschedule reason is required.")
        booking.status = "reschedule_by_provider"
        booking.proposed_time = _parse_dt(proposed_time)
        booking.cancel_reason = reason
        event = "reschedule_proposed"
        notif = dict(to=booking.customer_id, type="booking_status",
                     title="Reschedule proposed",
                     body=f"{me} suggested a new time: {reason}")

    elif action == "accept_proposal":
        booking.scheduled_at = booking.proposed_time
        booking.proposed_time = None
        amt = float(booking.advance_amount or 0)
        if booking.advance_paid:
            booking.status = "confirmed"
        elif amt > 0:
            booking.status = "awaiting_advance"
        else:
            booking.status = "pending"   # provider still needs to accept & set advance
        event = "proposal_accepted"
        notif = dict(to=booking.provider_id, type="booking_status",
                     title="New time accepted",
                     body=f"{me} accepted your proposed time.")

    elif action == "counter_proposal":
        if not proposed_time:
            raise WorkflowError(400, "proposed_time is required.")
        if not reason:
            raise WorkflowError(400, "A reason for the new time is required.")
        booking.status = "reschedule_by_customer"
        booking.proposed_time = _parse_dt(proposed_time)
        booking.cancel_reason = reason
        event = "counter_proposed"
        notif = dict(to=booking.provider_id, type="booking_status",
                     title="New time suggested",
                     body=f"{me} suggested another time: {reason}")

    elif action == "pay_advance":
        booking.status = "confirmed"
        booking.advance_paid = True
        event = "advance_paid"
        notif = dict(to=booking.provider_id, type="payment",
                     title="Advance paid — booking confirmed ✅",
                     body=f"{me} paid ₹{booking.advance_amount} advance. Booking is confirmed.")

    elif action == "cancel":
        booking.status = "cancelled_by_provider" if is_provider else "cancelled_by_customer"
        if reason:
            booking.cancel_reason = reason
        event = "cancelled"
        notif = dict(to=other_id, type="booking_status",
                     title="Booking cancelled",
                     body=f"{me} cancelled the booking." + (f" Reason: {reason}" if reason else ""))

    elif action == "start":
        booking.status = "in_progress"
        event = "started"
        notif = dict(to=booking.customer_id, type="booking_status",
                     title="Service started (Visiting)",
                     body=f"{me} has started your service.")

    elif action == "complete":
        booking.status = "completed"
        event = "completed"
        notif = dict(to=booking.customer_id, type="booking_status",
                     title="Service completed",
                     body="Service marked completed. Please rate the provider!")

    log_event(db, booking.id, user.id, role, event,
              reason=reason,
              proposed_time=_parse_dt(proposed_time) if proposed_time else None,
              amount=float(advance_amount) if advance_amount is not None else None)

    if notif:
        notify(db, notif["to"], notif["title"], notif["body"], notif["type"],
               booking.id, data={"screen": "booking", "booking_id": booking.id})

    db.commit()
    db.refresh(booking)
    return booking
