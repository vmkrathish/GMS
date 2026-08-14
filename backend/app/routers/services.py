# ─────────────────────────────────────────────
# /api/services — categories (emoji), the self-growing
# suggestion engine, and service CRUD with ratings +
# provider avatars. Response shapes match legacy exactly.
# ─────────────────────────────────────────────
import re

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.database.session import get_db
from app.middleware.deps import get_current_user
from app.models.models import SearchTerm, Service, ServiceCategory, User
from app.utils.helpers import jsonable

router = APIRouter(prefix="/api/services", tags=["Services"])

TERM_RE = re.compile(r"^[\w &+\-]+$", re.UNICODE)


def _fail(status: int, message: str):
    return JSONResponse(status_code=status,
                        content={"success": False, "message": message})


@router.get("/categories")
def get_categories(db: Session = Depends(get_db)):
    rows = (
        db.query(ServiceCategory)
        .filter(ServiceCategory.is_active == True)  # noqa: E712
        .order_by(ServiceCategory.sort_order, ServiceCategory.name)
        .all()
    )
    return {"success": True, "categories": [
        {"id": c.id, "name": c.name, "icon_name": c.icon_name,
         "emoji": c.emoji, "sort_order": c.sort_order} for c in rows]}


@router.get("/suggestions")
def get_suggestions(q: str = "", limit: int = Query(10, le=25),
                    db: Session = Depends(get_db)):
    q = (q or "").lower().strip()
    query = db.query(SearchTerm).filter(SearchTerm.is_approved == True)  # noqa: E712
    if q:
        query = query.filter(SearchTerm.term.like(f"%{q}%")).order_by(
            SearchTerm.term.like(f"{q}%").desc(),
            SearchTerm.hit_count.desc(),
            SearchTerm.term,
        )
    else:
        query = query.order_by(SearchTerm.hit_count.desc(), SearchTerm.term)
    rows = query.limit(limit).all()
    return {"success": True, "suggestions": [r.term for r in rows]}


@router.post("/suggestions")
def add_suggestion(body: dict, db: Session = Depends(get_db)):
    term = (body.get("term") or "").lower().strip()
    if len(term) < 2 or len(term) > 120:
        return _fail(400, "Invalid term.")
    if not TERM_RE.match(term):
        return _fail(400, "Term contains invalid characters.")

    existing = db.query(SearchTerm).filter(SearchTerm.term == term).first()
    if existing:
        existing.hit_count += 1          # popularity bump
    else:
        db.add(SearchTerm(term=term, source="user", hit_count=1))  # self-growing list
    db.commit()
    return {"success": True, "term": term}


# Rating aggregation reused by list + detail
RATING_SQL = """
    SELECT provider_id, ROUND(AVG(rating), 1) AS avg_rating, COUNT(*) AS review_count
    FROM reviews GROUP BY provider_id
"""


@router.get("")
@router.get("/")
def get_services(
    q: str | None = None,
    category_id: int | None = None,
    city: str | None = None,
    provider_id: int | None = None,
    page: int = 1,
    limit: int = Query(30, le=100),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    conditions = ["s.is_active = TRUE", "u.is_active = TRUE"]
    params: dict = {"limit": limit, "offset": (max(page, 1) - 1) * limit}
    if category_id:
        conditions.append("s.category_id = :category_id")
        params["category_id"] = category_id
    if provider_id:
        conditions.append("s.provider_id = :provider_id")
        params["provider_id"] = provider_id
    else:
        # General marketplace browsing/search never shows your own
        # listings back to you (booking yourself makes no sense) —
        # doesn't apply when someone explicitly asked for a specific
        # provider_id (e.g. viewing your own public profile on purpose).
        conditions.append("s.provider_id != :me")
        params["me"] = user.id
    if city:
        conditions.append("s.city ILIKE :city")
        params["city"] = f"%{city}%"
    if q:
        conditions.append(
            "(s.title ILIKE :q OR s.description ILIKE :q OR sc.name ILIKE :q OR u.name ILIKE :q)")
        params["q"] = f"%{q}%"

    rows = db.execute(text(f"""
        SELECT
          s.id, s.title, s.description, s.price, s.price_unit, s.is_primary, s.city,
          s.category_id, sc.name AS category_name, sc.emoji AS category_emoji,
          s.provider_id, u.name AS provider_name, u.avatar_url AS provider_avatar,
          COALESCE(r.avg_rating, 0)   AS average_rating,
          COALESCE(r.review_count, 0) AS review_count
        FROM services s
        JOIN service_categories sc ON s.category_id = sc.id
        JOIN users u ON s.provider_id = u.id
        LEFT JOIN ({RATING_SQL}) r ON r.provider_id = s.provider_id
        WHERE {' AND '.join(conditions)}
        ORDER BY average_rating DESC, s.created_at DESC
        LIMIT :limit OFFSET :offset
    """), params).mappings().all()

    return {"success": True,
            "services": [{k: jsonable(v) for k, v in row.items()} for row in rows]}


# ── GET /api/services/recommended ──────────────
# Powers the Home page's "Recommended for You" section with the
# logged-in user's saved Home location (users.latitude/longitude —
# the exact same column the profile's map picker already writes to;
# no new location data, no new tables).
#
# Ranking is a weighted blend of:
#   1. Distance       — via a portable haversine formula (great-circle,
#                        same one used everywhere else in this file —
#                        works identically on any SQL database, not
#                        tied to a MySQL-only function). Full weight
#                        for on-site trades, near-zero for
#                        remote-friendly categories (web dev, design,
#                        editing…), per service_categories.is_remote.
#   2. Rating          — existing reviews-based average.
#   3. Availability    — proxied by how recently the provider was
#                        last active (users.last_seen_at); there's no
#                        explicit booking-calendar/availability system
#                        yet, so recency of activity is the closest
#                        honest signal currently in the schema.
#   4. Relevance       — 1.0 whenever a q/category filter is satisfied
#                        (or by default when browsing with no filter).
#   5. Reputation      — completed job count from the existing
#                        bookings table (status='completed'), a more
#                        direct signal than review count alone since
#                        not every completed job gets reviewed.
#
# If the user has no saved Home location, this gracefully falls back
# to the same rating-sorted ordering /api/services already uses —
# existing behavior, unchanged, never a hard failure.
@router.get("/recommended")
def get_recommended_services(
    q: str | None = None,
    category_id: int | None = None,
    limit: int = Query(10, le=50),
    lat: float | None = None,
    lng: float | None = None,
    sort: str = "smart",  # "smart" = weighted composite (default),
                           # "distance" = pure nearest-first (KNN-style),
                           # used by the Home/Current toggle on Home
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    # If explicit coordinates are passed (the "Current location" mode),
    # use those directly instead of the saved Home location — same
    # endpoint, same ranking, just a different reference point.
    if lat is not None and lng is not None:
        home_lat, home_lng = lat, lng
    else:
        home = db.execute(
            text("SELECT latitude, longitude FROM users WHERE id = :id"),
            {"id": user.id},
        ).mappings().first()
        home_lat = float(home["latitude"]) if home and home["latitude"] is not None else None
        home_lng = float(home["longitude"]) if home and home["longitude"] is not None else None

    conditions = ["s.is_active = TRUE", "u.is_active = TRUE", "s.provider_id != :me"]
    params: dict = {"limit": limit, "me": user.id}
    if category_id:
        conditions.append("s.category_id = :category_id")
        params["category_id"] = category_id
    if q:
        conditions.append(
            "(s.title ILIKE :q OR s.description ILIKE :q OR sc.name ILIKE :q OR u.name ILIKE :q)")
        params["q"] = f"%{q}%"

    # ── No saved Home location → graceful fallback, unchanged from
    #    the existing /api/services default ordering. ──
    if home_lat is None or home_lng is None:
        rows = db.execute(text(f"""
            SELECT
              s.id, s.title, s.description, s.price, s.price_unit, s.is_primary, s.city,
              s.category_id, sc.name AS category_name, sc.emoji AS category_emoji,
              s.provider_id, u.name AS provider_name, u.avatar_url AS provider_avatar,
              COALESCE(r.avg_rating, 0)   AS average_rating,
              COALESCE(r.review_count, 0) AS review_count,
              NULL AS distance_km
            FROM services s
            JOIN service_categories sc ON s.category_id = sc.id
            JOIN users u ON s.provider_id = u.id
            LEFT JOIN ({RATING_SQL}) r ON r.provider_id = s.provider_id
            WHERE {' AND '.join(conditions)}
            ORDER BY average_rating DESC, s.created_at DESC
            LIMIT :limit
        """), params).mappings().all()
        return {
            "success": True,
            "location_available": False,
            "services": [{k: jsonable(v) for k, v in r.items()} for r in rows],
        }

    # ── Home location available → full weighted ranking ──
    params["home_lat"] = home_lat
    params["home_lng"] = home_lng

    rows = db.execute(text(f"""
        SELECT * FROM (
          SELECT
            s.id, s.title, s.description, s.price, s.price_unit, s.is_primary, s.city,
            s.category_id, sc.name AS category_name, sc.emoji AS category_emoji,
            sc.is_remote,
            s.provider_id, u.name AS provider_name, u.avatar_url AS provider_avatar,
            COALESCE(r.avg_rating, 0)   AS average_rating,
            COALESCE(r.review_count, 0) AS review_count,
            COALESCE(c.completed_jobs, 0) AS completed_jobs,
            6371 * ACOS(LEAST(1, GREATEST(-1,
              COS(RADIANS(:home_lat)) * COS(RADIANS(u.latitude)) *
              COS(RADIANS(u.longitude) - RADIANS(:home_lng)) +
              SIN(RADIANS(:home_lat)) * SIN(RADIANS(u.latitude))
            ))) AS distance_km,
            -- Availability proxy: recency of last activity.
            CASE
              WHEN u.last_seen_at >= NOW() - INTERVAL '1 hour' THEN 1.0
              WHEN u.last_seen_at >= NOW() - INTERVAL '1 day'  THEN 0.7
              WHEN u.last_seen_at >= NOW() - INTERVAL '7 days' THEN 0.4
              ELSE 0.1
            END AS availability_score
          FROM services s
          JOIN service_categories sc ON s.category_id = sc.id
          JOIN users u ON s.provider_id = u.id
          LEFT JOIN ({RATING_SQL}) r ON r.provider_id = s.provider_id
          LEFT JOIN (
            SELECT provider_id, COUNT(*) AS completed_jobs
            FROM bookings WHERE status = 'completed' GROUP BY provider_id
          ) c ON c.provider_id = s.provider_id
          WHERE {' AND '.join(conditions)}
            AND u.latitude IS NOT NULL AND u.longitude IS NOT NULL
        ) sub
        WHERE is_remote = TRUE OR distance_km <= 50
    """), params).mappings().all()

    # Weighted composite score, computed in Python for clarity —
    # two weight sets depending on whether the category is remote-
    # friendly (distance barely matters) or on-site (distance matters
    # most). Weights each sum to 1.0.
    # Distance carries genuinely HIGH weight for on-site trades (as
    # requested) — high enough that a nearby average provider beats a
    # distant excellent one, not just a mild tiebreaker. Low weight
    # for remote-friendly categories, where distance barely matters.
    ON_SITE_W = {"distance": 0.50, "rating": 0.20, "availability": 0.10,
                 "relevance": 0.10, "reputation": 0.10}
    REMOTE_W = {"distance": 0.00, "rating": 0.35, "availability": 0.20,
                "relevance": 0.20, "reputation": 0.25}

    scored = []
    for row in rows:
        d = dict(row)
        weights = REMOTE_W if d["is_remote"] else ON_SITE_W
        distance_km = float(d["distance_km"]) if d["distance_km"] is not None else 999
        # Smooth decay, never floors to a flat value — someone 300km
        # away always scores meaningfully worse than someone 30km
        # away, who always scores worse than someone 3km away. A hard
        # cutoff (e.g. treating everything past 50km as equally "0")
        # would let rating alone decide once a provider crosses that
        # line, which undersells how much distance should matter.
        distance_score = 1 / (1 + distance_km / 25)
        rating_score = float(d["average_rating"]) / 5
        availability_score = float(d["availability_score"])
        relevance_score = 1.0  # filter (if any) already applied in SQL WHERE
        reputation_score = min(1.0, float(d["completed_jobs"]) / 10)

        composite = (
            weights["distance"] * distance_score +
            weights["rating"] * rating_score +
            weights["availability"] * availability_score +
            weights["relevance"] * relevance_score +
            weights["reputation"] * reputation_score
        )
        d["composite_score"] = round(composite, 4)
        d["_distance_for_sort"] = distance_km
        scored.append(d)

    if sort == "distance":
        # Pure nearest-to-farthest ordering (KNN-style) — ignores
        # rating/availability/reputation entirely, just distance
        # ascending. Remote-friendly categories (no real distance
        # concept) sort after every on-site result, nearest-first
        # among themselves.
        scored.sort(key=lambda d: (d["is_remote"], d["_distance_for_sort"]))
    else:
        scored.sort(key=lambda d: d["composite_score"], reverse=True)
    top = scored[:limit]

    return {
        "success": True,
        "location_available": True,
        "sort": sort,
        "services": [{k: jsonable(v) for k, v in d.items()
                     if k not in ("is_remote", "_distance_for_sort")}
                     for d in top],
    }


# ── GET /api/services/nearby ───────────────────
# Rapido-style radius-expanding discovery: tries 5km, then 10, 20,
# and finally 50km — returns the FIRST tier that has any results, so
# the map always shows the tightest, most relevant radius rather than
# always maxing out at 50km. Never searches beyond 50km.
#
# If nothing at all matches the category within 50km, falls back to a
# broader text search (title/description/category name) at the same
# 50km ceiling, flagged as `is_similar: true` — covers a provider
# whose matching service is a secondary listing, or a closely related
# trade, rather than just saying nothing exists nearby.
RADIUS_TIERS_KM = [5, 10, 20, 50]

# Haversine distance in km between (lat,lng) and the provider's
# registered location. Services don't carry their own coordinates —
# a home-service provider's registered address IS their service area.
DISTANCE_SQL = """
    6371 * ACOS(LEAST(1, GREATEST(-1,
      COS(RADIANS(:lat)) * COS(RADIANS(u.latitude)) *
      COS(RADIANS(u.longitude) - RADIANS(:lng)) +
      SIN(RADIANS(:lat)) * SIN(RADIANS(u.latitude))
    )))
"""


@router.get("/nearby")
def get_nearby_services(
    lat: float,
    lng: float,
    category_id: int | None = None,
    q: str | None = None,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    base_conditions = [
        "s.is_active = TRUE", "u.is_active = TRUE",
        "u.latitude IS NOT NULL", "u.longitude IS NOT NULL",
        "s.provider_id != :me",  # never show yourself on the map
    ]
    params: dict = {"lat": lat, "lng": lng, "me": user.id}

    def run(conditions: list[str], extra_params: dict, max_km: float):
        p = {**params, **extra_params, "max_km": max_km}
        rows = db.execute(text(f"""
            SELECT * FROM (
              SELECT
                s.id, s.title, s.description, s.price, s.price_unit, s.is_primary, s.city,
                s.category_id, sc.name AS category_name, sc.emoji AS category_emoji,
                s.provider_id, u.name AS provider_name, u.avatar_url AS provider_avatar,
                u.latitude AS provider_lat, u.longitude AS provider_lng,
                COALESCE(r.avg_rating, 0)   AS average_rating,
                COALESCE(r.review_count, 0) AS review_count,
                ({DISTANCE_SQL}) AS distance_km
              FROM services s
              JOIN service_categories sc ON s.category_id = sc.id
              JOIN users u ON s.provider_id = u.id
              LEFT JOIN ({RATING_SQL}) r ON r.provider_id = s.provider_id
              WHERE {' AND '.join(conditions)}
            ) sub
            WHERE distance_km <= :max_km
            ORDER BY distance_km ASC
        """), p).mappings().all()
        return rows

    # ── No filter at all — this is the Map screen's default view on
    #    open, before any search: show EVERYONE active within 50km,
    #    nearest first. Only an explicit search narrows it further.
    if category_id is None and not q:
        rows = run(base_conditions, {}, 50)
        return {
            "success": True,
            "radius_used_km": 50,
            "is_similar": False,
            "default_view": True,
            "services": [{k: jsonable(v) for k, v in r.items()} for r in rows],
        }

    # ── Primary search, tier-escalated 5→10→20→50km ──
    # If a category_id was given, match it exactly. If only free text
    # was given (this is what the map's search bar sends), try to
    # resolve it to a real category first (so "plumber" behaves
    # exactly like selecting the Plumbing category) — this used to be
    # skipped entirely, which meant every text search jumped straight
    # to a flat, unescalated 50km lookup even when someone was right
    # next door.
    primary_conditions = list(base_conditions)
    primary_params: dict = {}
    if category_id is not None:
        primary_conditions.append("s.category_id = :category_id")
        primary_params["category_id"] = category_id
    elif q:
        matched_cat = db.execute(
            text("SELECT id FROM service_categories WHERE name ILIKE :q LIMIT 1"),
            {"q": f"%{q}%"},
        ).mappings().first()
        if matched_cat:
            primary_conditions.append("s.category_id = :category_id")
            primary_params["category_id"] = matched_cat["id"]
        else:
            primary_conditions.append(
                "(s.title ILIKE :q OR s.description ILIKE :q OR sc.name ILIKE :q)")
            primary_params["q"] = f"%{q}%"

    for radius in RADIUS_TIERS_KM:
        rows = run(primary_conditions, primary_params, radius)
        if rows:
            return {
                "success": True,
                "radius_used_km": radius,
                "is_similar": False,
                "services": [{k: jsonable(v) for k, v in r.items()} for r in rows],
            }

    # ── Fallback: broader fuzzy text match, ALSO tier-escalated ──
    # Reached only if the primary search found nobody at all within
    # 50km. Covers a provider whose matching service is a secondary
    # listing, or a closely related trade, rather than the exact
    # category/term. Still capped at 50km, never wider.
    text_term = q
    if text_term is None and category_id is not None:
        cat = db.execute(text("SELECT name FROM service_categories WHERE id = :id"),
                          {"id": category_id}).mappings().first()
        text_term = cat["name"] if cat else None

    if text_term:
        fallback_conditions = base_conditions + [
            "(s.title ILIKE :q OR s.description ILIKE :q OR sc.name ILIKE :q)"
        ]
        for radius in RADIUS_TIERS_KM:
            rows = run(fallback_conditions, {"q": f"%{text_term}%"}, radius)
            if rows:
                return {
                    "success": True,
                    "radius_used_km": radius,
                    "is_similar": True,
                    "services": [{k: jsonable(v) for k, v in r.items()} for r in rows],
                }

    # ── Truly nothing within 50km — suggest what IS actually
    #    available nearby, rather than a dead-end message. This
    #    queries real data (not a guessed "electrician relates to X"
    #    table), so the suggestions are always genuinely bookable.
    nearby_categories = db.execute(text(f"""
        SELECT DISTINCT id, name, emoji, distance_km FROM (
          SELECT sc.id, sc.name, sc.emoji, ({DISTANCE_SQL}) AS distance_km
          FROM services s
          JOIN service_categories sc ON s.category_id = sc.id
          JOIN users u ON s.provider_id = u.id
          WHERE s.is_active = TRUE AND u.is_active = TRUE
            AND u.latitude IS NOT NULL AND u.longitude IS NOT NULL
            AND s.provider_id != :me
        ) sub
        WHERE distance_km <= 50
        ORDER BY distance_km ASC
        LIMIT 60
    """), {"lat": lat, "lng": lng, "me": user.id}).mappings().all()

    seen = set()
    suggested = []
    for r in nearby_categories:
        if r["id"] in seen:
            continue
        seen.add(r["id"])
        suggested.append({"id": r["id"], "name": r["name"], "emoji": r["emoji"]})
        if len(suggested) >= 6:
            break

    return {
        "success": True,
        "radius_used_km": 50,
        "is_similar": False,
        "services": [],
        "message": "No providers found within 50 km for that search. "
                    "Here's what IS available near you instead:"
                    if suggested else
                    "No providers found within 50 km. Try a different "
                    "service, or check back soon as more providers join "
                    "GMS in your area.",
        "suggested_categories": suggested,
    }


@router.get("/{service_id}")
def get_service(service_id: int, db: Session = Depends(get_db)):
    row = db.execute(text(f"""
        SELECT
          s.*, sc.name AS category_name, sc.emoji AS category_emoji,
          u.name AS provider_name, u.avatar_url AS provider_avatar,
          u.bio AS provider_bio, u.city AS provider_city,
          COALESCE(r.avg_rating, 0)   AS average_rating,
          COALESCE(r.review_count, 0) AS review_count
        FROM services s
        JOIN service_categories sc ON s.category_id = sc.id
        JOIN users u ON s.provider_id = u.id
        LEFT JOIN ({RATING_SQL}) r ON r.provider_id = s.provider_id
        WHERE s.id = :sid AND s.is_active = TRUE
    """), {"sid": service_id}).mappings().first()
    if not row:
        return _fail(404, "Service not found.")
    return {"success": True, "service": {k: jsonable(v) for k, v in row.items()}}


@router.post("")
@router.post("/")
def create_service(body: dict, user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)):
    title = (body.get("title") or "").strip()
    city = (body.get("city") or "").strip()
    category_id = body.get("category_id")
    price = body.get("price")
    if not title or not city or not category_id or price is None:
        return _fail(400, "title, category_id, price and city are required.")

    is_primary = bool(body.get("is_primary"))
    if is_primary:
        # Only ONE primary service per provider (You-page rule)
        db.query(Service).filter(Service.provider_id == user.id).update(
            {"is_primary": False})

    svc = Service(
        provider_id=user.id,
        category_id=int(category_id),
        title=title,
        description=(body.get("description") or "").strip() or None,
        price=float(price),
        price_unit=body.get("price_unit") or "fixed",
        city=city,
        is_primary=is_primary,
    )
    db.add(svc)
    db.commit()
    db.refresh(svc)
    return JSONResponse(status_code=201, content={
        "success": True,
        "service": {"id": svc.id, "title": svc.title,
                    "price": f"{svc.price:.2f}", "price_unit": svc.price_unit,
                    "city": svc.city, "is_primary": 1 if svc.is_primary else 0}})


@router.put("/{service_id}")
def update_service(service_id: int, body: dict,
                   user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)):
    svc = db.get(Service, service_id)
    if not svc or svc.provider_id != user.id:
        return _fail(404, "Service not found.")

    if body.get("is_primary"):
        db.query(Service).filter(Service.provider_id == user.id).update(
            {"is_primary": False})
        svc.is_primary = True
    for key in ("title", "description", "city"):
        if key in body and isinstance(body[key], str):
            setattr(svc, key, body[key].strip())
    if "price" in body:
        svc.price = float(body["price"])
    if "price_unit" in body:
        svc.price_unit = body["price_unit"]
    if "is_active" in body:
        svc.is_active = bool(body["is_active"])
    db.commit()
    return {"success": True, "message": "Service updated."}


@router.delete("/{service_id}")
def delete_service(service_id: int, user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)):
    svc = db.get(Service, service_id)
    if not svc or svc.provider_id != user.id:
        return _fail(404, "Service not found.")
    svc.is_active = False   # soft delete — bookings keep their FK
    db.commit()
    return {"success": True, "message": "Service removed."}
