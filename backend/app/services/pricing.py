# Platform-controlled pricing — base price calculation, review-gated
# increase eligibility, and backend price validation.
#
# Reviews are tied to provider_id on the reviews table, not
# service_id directly — but every review has a booking_id, and every
# booking has a service_id, so a genuinely SERVICE-SPECIFIC rating
# (not the provider's overall rating) is available through that
# existing chain (reviews -> bookings -> service_id) without adding
# a redundant column. This is what makes "Bike Repair = 4.8, Plumbing
# = 4.1 for the same provider" (spec item 21) actually correct.
import logging
from datetime import datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.models.models import MarketPriceReference, PriceHistory, PricingState, Service

log = logging.getLogger("gms.pricing")


def get_config(db: Session, key: str, default: str) -> str:
    row = db.execute(text("SELECT value FROM platform_config WHERE key = :k"),
                      {"k": key}).first()
    return row[0] if row else default


def get_config_decimal(db: Session, key: str, default: str) -> Decimal:
    return Decimal(get_config(db, key, default))


def _round2(value: Decimal) -> Decimal:
    return value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def calculate_base_price(db: Session, category_id: int, price_unit: str,
                          city: str | None) -> Decimal | None:
    """Blends the general/national reference with the locality
    reference for this exact (category, price_unit) pair — fixed,
    hourly, and daily are NEVER mixed together, matching spec item 2.

    Returns None if no reference data exists at all yet for this
    combination — callers must handle that (e.g. by falling back to
    letting an admin set the price manually) rather than fabricating
    a number.
    """
    general = db.query(MarketPriceReference).filter(
        MarketPriceReference.category_id == category_id,
        MarketPriceReference.price_unit == price_unit,
        MarketPriceReference.city.is_(None),
    ).first()

    locality = None
    if city:
        locality = db.query(MarketPriceReference).filter(
            MarketPriceReference.category_id == category_id,
            MarketPriceReference.price_unit == price_unit,
            MarketPriceReference.city.ilike(city),
        ).first()

    if general is None and locality is None:
        log.info("pricing: no market reference for category_id=%s "
                 "price_unit=%s city=%s — cannot calculate base price",
                 category_id, price_unit, city)
        return None

    # Only one of the two exists — use it directly rather than
    # blending against nothing.
    if general is None:
        return _round2(locality.typical_price)
    if locality is None:
        return _round2(general.typical_price)

    # Both exist — weighted blend, weight configurable (spec item 4:
    # "should avoid simply trusting one... the exact weighting
    # should be configurable rather than hard-coded").
    general_weight = get_config_decimal(db, "market_general_weight", "0.5")
    locality_weight = Decimal("1") - general_weight
    blended = (general.typical_price * general_weight +
               locality.typical_price * locality_weight)
    return _round2(blended)


def service_quality_rating(db: Session, service_id: int) -> tuple[Decimal | None, int]:
    """Average rating for THIS SPECIFIC SERVICE (not the provider's
    overall rating) over the configured quality period — via the
    reviews -> bookings -> service_id chain described above. Returns
    (average_or_None, review_count) — None average means zero
    qualifying reviews, never treated the same as a real low rating.
    """
    months = int(get_config(db, "quality_period_months", "3"))
    cutoff = datetime.now() - timedelta(days=months * 30)

    row = db.execute(text("""
        SELECT AVG(r.rating) AS avg_rating, COUNT(*) AS review_count
        FROM reviews r
        JOIN bookings b ON b.id = r.booking_id
        WHERE b.service_id = :sid AND r.created_at >= :cutoff
    """), {"sid": service_id, "cutoff": cutoff}).mappings().first()

    count = row["review_count"] or 0
    if count == 0:
        return None, 0
    return Decimal(str(row["avg_rating"])), count


def check_increase_eligibility(db: Session, service_id: int) -> tuple[bool, Decimal | None, int]:
    threshold = get_config_decimal(db, "rating_qualification_threshold", "4.5")
    avg, count = service_quality_rating(db, service_id)
    eligible = avg is not None and avg > threshold
    return eligible, avg, count


def get_or_create_pricing_state(db: Session, service: Service) -> PricingState:
    """Ensures a pricing_state row exists for this service —
    calculates one from market reference data if this is the first
    time. Does NOT overwrite an existing base price (that only
    changes through apply_price_change, with a proper audit row —
    see spec items 11/12: a reduced base price must stick, never
    silently reset back to a recalculated market figure).
    """
    state = db.query(PricingState).filter(
        PricingState.service_id == service.id).first()
    if state:
        return state

    base = calculate_base_price(db, service.category_id, service.price_unit,
                                 service.city)
    if base is None:
        # No market data yet for this category/model/locality —
        # honest fallback: use whatever the provider's service
        # already had as price (e.g. from initial creation) as the
        # starting base, rather than blocking them entirely. An
        # admin adding market reference data later will not
        # retroactively change this — see calculate/recalculate
        # distinction in apply_price_change.
        base = Decimal(str(service.price)) if service.price else Decimal("0")
        log.info("pricing: service_id=%s has no market reference — "
                 "using existing service price %s as initial base",
                 service.id, base)

    increase_pct = get_config_decimal(db, "max_price_increase_pct", "20")
    max_allowed = _round2(base * (Decimal("1") + increase_pct / Decimal("100")))

    state = PricingState(service_id=service.id, base_price=base,
                         max_allowed_price=max_allowed,
                         price_increase_eligible=False)
    db.add(state)
    db.flush()

    db.add(PriceHistory(
        service_id=service.id, previous_base_price=None, new_base_price=base,
        change_percent=None, reason="Initial base price calculated from "
        "market reference data", max_allowed_price=max_allowed,
        triggered_by="market_calculation",
    ))
    return state


def refresh_eligibility(db: Session, service: Service) -> PricingState:
    """Re-evaluates whether this service currently qualifies for the
    price-increase allowance — call this whenever it matters (price
    edit attempt, provider dashboard load) rather than on a
    background schedule, since eligibility is cheap to compute and
    always needs to reflect the CURRENT review window, not a stale
    cached value.
    """
    state = get_or_create_pricing_state(db, service)
    eligible, avg, count = check_increase_eligibility(db, service.id)
    if state.price_increase_eligible != eligible:
        log.info("pricing: service_id=%s eligibility changed %s -> %s "
                 "(3-month avg=%s over %d review(s))",
                 service.id, state.price_increase_eligible, eligible, avg, count)
        state.price_increase_eligible = eligible
        state.last_calculated_at = datetime.now()
    return state


def apply_price_change(db: Session, service: Service, new_base_price: Decimal,
                       reason: str, triggered_by: str) -> PricingState:
    """The ONLY correct way to change a service's base price — spec
    items 11/12: a reduced (or increased) base price becomes the new
    starting point for every future calculation; it is never
    silently reset back to a fresh market-only recalculation. Always
    writes a price_history row.
    """
    state = get_or_create_pricing_state(db, service)
    previous = state.base_price
    change_pct = (_round2((new_base_price - previous) / previous * 100)
                 if previous and previous != 0 else None)

    increase_pct = get_config_decimal(db, "max_price_increase_pct", "20")
    new_max = _round2(new_base_price * (Decimal("1") + increase_pct / Decimal("100")))

    state.base_price = new_base_price
    state.max_allowed_price = new_max
    state.updated_at = datetime.now()

    db.add(PriceHistory(
        service_id=service.id, previous_base_price=previous,
        new_base_price=new_base_price, change_percent=change_pct,
        reason=reason, max_allowed_price=new_max, triggered_by=triggered_by,
    ))
    return state


def validate_requested_price(db: Session, service: Service,
                              requested_price: Decimal) -> tuple[bool, str]:
    """The actual backend enforcement — spec item 9/10: never trust
    frontend validation alone. Returns (is_valid, message).
    """
    state = refresh_eligibility(db, service)
    floor = state.base_price
    ceiling = state.max_allowed_price if state.price_increase_eligible else state.base_price

    if requested_price < floor or requested_price > ceiling:
        return False, (f"Invalid price. Your current allowed price range is "
                       f"₹{floor}–₹{ceiling}. Please enter a value within "
                       f"this range.")
    return True, ""
