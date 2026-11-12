# /api/geo — server-side reverse geocoding.
#
# WHY THIS EXISTS: the Flutter `geocoding` plugin has NO Web
# implementation (Android/iOS/macOS only — this is a documented
# limitation of the plugin, not a bug in this app). Calling it from
# Flutter Web throws, and the client-side fallback silently showed
# raw latitude/longitude instead of a readable address. Doing the
# reverse-geocode call here, server-side, works identically on every
# platform the app runs on — web, Android, iOS, desktop — since the
# client only ever asks this backend for a plain address string.
#
# Uses OpenStreetMap's free Nominatim API. Their usage policy requires
# a descriptive User-Agent and a soft cap of ~1 request/second, which
# is exactly what a single "reverse geocode where I tapped the map"
# action needs — no API key required.

import logging

import requests
from fastapi import APIRouter, Depends

from app.middleware.deps import get_current_user
from app.models.models import User

log = logging.getLogger("gms.geo")

router = APIRouter(prefix="/api/geo", tags=["Geo"])

NOMINATIM_URL = "https://nominatim.openstreetmap.org/reverse"
HEADERS = {"User-Agent": "GMS-GetMyService/1.0 (service marketplace app)"}


@router.get("/reverse")
def reverse_geocode(lat: float, lng: float,
                     _: User = Depends(get_current_user)):
    """Returns a short, human-readable place name for a coordinate —
    never raw numbers. Falls back gracefully if the geocoding service
    is unreachable."""
    try:
        resp = requests.get(
            NOMINATIM_URL,
            params={"lat": lat, "lon": lng, "format": "jsonv2", "zoom": 16},
            headers=HEADERS,
            timeout=6,
        )
        if resp.status_code != 200:
            return {"success": False, "address": None}

        data = resp.json()
        addr = data.get("address", {})

        # Build a short label: nearest named place + locality + district
        # e.g. "Sankagiri, Salem District, Tamil Nadu"
        parts = []
        for key in ("suburb", "neighbourhood", "village", "town", "city_district"):
            if addr.get(key):
                parts.append(addr[key])
                break
        for key in ("city", "town", "county"):
            if addr.get(key) and addr[key] not in parts:
                parts.append(addr[key])
                break
        if addr.get("state") and addr["state"] not in parts:
            parts.append(addr["state"])

        label = ", ".join(parts) if parts else data.get("display_name", "")

        return {
            "success": True,
            "address": label or None,
            # Structured components — used by the Edit Profile screen
            # to autofill individual form fields (city, state, pincode…)
            # rather than just displaying one line of text.
            "components": {
                "name": addr.get("suburb") or addr.get("neighbourhood") or addr.get("road"),
                "street": addr.get("road"),
                "sublocality": addr.get("suburb") or addr.get("neighbourhood"),
                "sub_administrative_area": addr.get("county") or addr.get("city_district"),
                "locality": addr.get("city") or addr.get("town") or addr.get("village"),
                "state": addr.get("state"),
                "postal_code": addr.get("postcode"),
                "country": addr.get("country"),
            },
        }
    except Exception:
        return {"success": False, "address": None, "components": None}


# ─────────────────────────────────────────────
# WHY THIS EXISTS: showing "12.4 km away" (straight-line distance) is
# useful for ranking/sorting, but doesn't tell someone how far they'd
# actually have to drive — roads curve, rivers and hills get in the
# way. This proxies OSRM (Open Source Routing Machine, built on
# OpenStreetMap data — the same map data source already used
# throughout this app) to get real driving distance, estimated time,
# and the actual route line to draw on the map — the Google-Maps-style
# "how far, how long" view shown before booking someone.
# Free public demo server, no API key required.
# ─────────────────────────────────────────────
OSRM_URL = "https://router.project-osrm.org/route/v1/driving"


@router.get("/route")
def driving_route(from_lat: float, from_lng: float,
                   to_lat: float, to_lng: float,
                   _: User = Depends(get_current_user)):
    """Real driving distance/duration + route polyline between two
    points, via OSRM. Falls back gracefully (success: false) if the
    routing service is unreachable — callers should fall back to the
    straight-line distance they already have rather than block."""
    try:
        # OSRM takes coordinates as lng,lat (GeoJSON order, not lat,lng)
        coords = f"{from_lng},{from_lat};{to_lng},{to_lat}"
        resp = requests.get(
            f"{OSRM_URL}/{coords}",
            params={"overview": "full", "geometries": "geojson"},
            headers=HEADERS,
            timeout=8,
        )
        if resp.status_code != 200:
            return {"success": False}

        data = resp.json()
        if data.get("code") != "Ok" or not data.get("routes"):
            return {"success": False}

        route = data["routes"][0]
        # GeoJSON polyline is [lng, lat] pairs — flip to [lat, lng] for
        # flutter_map's LatLng convention.
        polyline = [[pt[1], pt[0]] for pt in route["geometry"]["coordinates"]]

        return {
            "success": True,
            "distance_km": round(route["distance"] / 1000, 2),
            "duration_min": round(route["duration"] / 60),
            "polyline": polyline,
        }
    except Exception:
        return {"success": False}


# ─────────────────────────────────────────────
# WHY THIS EXISTS: the Edit Profile screen auto-fills City from a
# 6-digit Indian PIN code rather than letting it be typed freely —
# PIN code is the single source of truth for locality here, so this
# is what actually resolves "637301" → "Sankagiri" server-side, for
# the same reason reverse-geocoding is server-side above (consistent
# CORS-free behavior on every platform, no client API key needed).
# Uses India Post's own free public PIN code lookup.
# ─────────────────────────────────────────────
PINCODE_URL = "https://api.postalpincode.in/pincode"
PINCODE_FALLBACK_URL = "https://api.zippopotam.us/in"


@router.get("/pincode")
def lookup_pincode(code: str, _: User = Depends(get_current_user)):
    code = (code or "").strip()
    if not code.isdigit() or len(code) != 6:
        return {"success": False, "message": "Enter a valid 6-digit PIN code."}

    log.info("pincode lookup: code=%s (primary: postalpincode.in)", code)
    try:
        resp = requests.get(f"{PINCODE_URL}/{code}", headers=HEADERS, timeout=8)
        log.info("pincode lookup: primary responded status=%s", resp.status_code)
        if resp.status_code == 200:
            data = resp.json()
            if data and data[0].get("Status") == "Success":
                offices = data[0].get("PostOffice") or []
                if offices:
                    # A single PIN code often covers several post
                    # offices — just taking offices[0] isn't reliable,
                    # since the API doesn't guarantee the recognizable
                    # town is listed first. India Post's own
                    # BranchType field tells us which one actually IS
                    # the main town-level office: "Head Post Office"
                    # and "Sub Post Office" are real towns; "Branch
                    # Post Office" is often a small hamlet. Prefer
                    # HO/SO over BO — this is exactly the fix for
                    # 637301 sometimes surfacing an obscure locality
                    # instead of Sankagiri.
                    priority = {"Head Post Office": 0, "Sub Post Office": 1}
                    offices_sorted = sorted(
                        offices,
                        key=lambda o: priority.get(o.get("BranchType"), 2),
                    )
                    office = offices_sorted[0]
                    result = {
                        "success": True,
                        "city": office.get("Name") or office.get("Block") or "",
                        "district": office.get("District") or "",
                        "state": office.get("State") or "",
                        "country": office.get("Country") or "India",
                    }
                    log.info("pincode lookup: primary OK, city=%s "
                            "(chosen from %d offices, branch_type=%s)",
                            result["city"], len(offices),
                            office.get("BranchType"))
                    return result
            log.warning("pincode lookup: primary returned no match for %s "
                        "(status=%s) — trying fallback",
                        code, data[0].get("Status") if data else "empty-body")
        else:
            log.warning("pincode lookup: primary non-200 (%s) — trying fallback",
                        resp.status_code)
    except Exception as e:
        log.warning("pincode lookup: primary request failed (%s: %s) — "
                    "trying fallback", type(e).__name__, e)

    # Fallback: Zippopotam.us — a different provider on a different
    # domain, so a rate-limit or outage on the primary doesn't leave
    # this feature completely dead. Coarser data (no Block/taluk
    # level), but "places[0]" gives a usable city name.
    try:
        resp = requests.get(f"{PINCODE_FALLBACK_URL}/{code}",
                            headers=HEADERS, timeout=8)
        log.info("pincode lookup: fallback responded status=%s", resp.status_code)
        if resp.status_code == 200:
            data = resp.json()
            places = data.get("places") or []
            if places:
                place = places[0]
                result = {
                    "success": True,
                    "city": place.get("place name") or "",
                    "district": "",
                    "state": place.get("state") or "",
                    "country": "India",
                }
                log.info("pincode lookup: fallback OK, city=%s", result["city"])
                return result
    except Exception as e:
        log.error("pincode lookup: fallback ALSO failed for %s (%s: %s)",
                  code, type(e).__name__, e)

    log.error("pincode lookup: no provider found a match for %s", code)
    return {"success": False, "message": "PIN code not found."}


# India's states never meaningfully change — a hardcoded list here is
# faster and more reliable than a network call for the overwhelming
# majority of this app's users, and has zero chance of external-API
# downtime affecting the single most common case.
INDIAN_STATES = [
    "ANDHRA PRADESH", "ARUNACHAL PRADESH", "ASSAM", "BIHAR", "CHHATTISGARH",
    "DELHI", "GOA", "GUJARAT", "HARYANA", "HIMACHAL PRADESH",
    "JAMMU & KASHMIR", "JHARKHAND", "KARNATAKA", "KERALA", "MADHYA PRADESH",
    "MAHARASHTRA", "MANIPUR", "MEGHALAYA", "MIZORAM", "NAGALAND", "ODISHA",
    "PUNJAB", "RAJASTHAN", "SIKKIM", "TAMIL NADU", "TELANGANA", "TRIPURA",
    "UTTAR PRADESH", "UTTARAKHAND", "WEST BENGAL",
]

STATES_BY_COUNTRY_URL = "https://countriesnow.space/api/v0.1/countries/states"


@router.get("/states")
def states_for_country(country: str, _: User = Depends(get_current_user)):
    country = (country or "").strip()
    if country.lower() == "india":
        return {"success": True, "states": INDIAN_STATES}

    try:
        resp = requests.post(STATES_BY_COUNTRY_URL, json={"country": country},
                             headers=HEADERS, timeout=8)
        if resp.status_code != 200:
            return {"success": False, "states": []}
        data = resp.json()
        states = [s.get("name") for s in (data.get("data", {}).get("states") or [])
                  if s.get("name")]
        return {"success": True, "states": states}
    except Exception as e:
        log.warning("states-for-country: lookup failed for %r (%s: %s)",
                    country, type(e).__name__, e)
        return {"success": False, "states": []}


# Tamil Nadu's 38 districts — hardcoded for the same reason India's
# state list is: this data almost never changes, and a hardcoded list
# is faster and more reliable than any network call. This is this
# app's primary/most-used state by far, so it's covered completely.
# Other states aren't hardcoded here yet — see the honest fallback
# behavior below rather than guessing at data that could be wrong.
DISTRICTS_BY_STATE = {
    "TAMIL NADU": [
        "Ariyalur", "Chengalpattu", "Chennai", "Coimbatore", "Cuddalore",
        "Dharmapuri", "Dindigul", "Erode", "Kallakurichi", "Kanchipuram",
        "Kanyakumari", "Karur", "Krishnagiri", "Madurai", "Mayiladuthurai",
        "Nagapattinam", "Namakkal", "Nilgiris", "Perambalur", "Pudukkottai",
        "Ramanathapuram", "Ranipet", "Salem", "Sivaganga", "Tenkasi",
        "Thanjavur", "Theni", "Thoothukudi", "Tiruchirappalli", "Tirunelveli",
        "Tirupattur", "Tiruppur", "Tiruvallur", "Tiruvannamalai", "Tiruvarur",
        "Vellore", "Viluppuram", "Virudhunagar",
    ],
}


@router.get("/districts")
def districts_for_state(state: str, _: User = Depends(get_current_user)):
    state = (state or "").strip().upper()
    districts = DISTRICTS_BY_STATE.get(state)
    if districts:
        return {"success": True, "districts": districts}
    # Honest fallback — no guessed/incomplete data for states not
    # covered above. The frontend should let District stay free-text
    # in this case rather than show an empty, broken-looking dropdown.
    log.info("districts-for-state: no hardcoded list for %r yet", state)
    return {"success": False, "districts": []}


# ─────────────────────────────────────────────
# WHY THIS EXISTS: City is a free-text field again (not locked to
# pincode-only auto-fill) — this is what powers the as-you-type
# suggestion dropdown, matching the exact autocomplete pattern
# already used for the Home/Map search bars. Reuses the same postal
# API, this time searching BY name instead of by pincode.
# ─────────────────────────────────────────────
POSTOFFICE_NAME_URL = "https://api.postalpincode.in/postoffice"


@router.get("/city-suggestions")
def city_suggestions(q: str, state: str = "", district: str = "",
                     _: User = Depends(get_current_user)):
    q = (q or "").strip()
    state = (state or "").strip().upper()
    district = (district or "").strip().upper()
    if len(q) < 3:
        return {"success": True, "suggestions": []}

    try:
        resp = requests.get(f"{POSTOFFICE_NAME_URL}/{q}", headers=HEADERS, timeout=8)
        if resp.status_code != 200:
            return {"success": True, "suggestions": []}

        data = resp.json()
        if not data or data[0].get("Status") != "Success":
            return {"success": True, "suggestions": []}

        offices = data[0].get("PostOffice") or []
        # Dedupe by (name, district) — the same locality name can
        # legitimately appear once per nearby post office otherwise.
        seen = set()
        suggestions = []
        for office in offices:
            name = (office.get("Name") or "").strip()
            office_district = (office.get("District") or "").strip()
            pincode = (office.get("Pincode") or "").strip()
            office_state = (office.get("State") or "").strip()
            branch_type = office.get("BranchType") or ""
            if not name or (name, office_district) in seen:
                continue
            # Major places only — a Branch Post Office is very often a
            # tiny hamlet (this is exactly what caused an obscure
            # locality to outrank Sankagiri before). Head/Sub Post
            # Office reliably means a real town or municipality.
            if branch_type == "Branch Post Office":
                continue
            # Scope to the state (and district, once picked) — a name
            # search alone can return matches from anywhere in the
            # country, most of which aren't relevant.
            if state and office_state.strip().upper() != state:
                continue
            if district and office_district.strip().upper() != district:
                continue
            seen.add((name, office_district))
            suggestions.append({
                "city": name,
                "district": office_district,
                "state": office_state,
                "pincode": pincode,
            })
            if len(suggestions) >= 10:
                break

        return {"success": True, "suggestions": suggestions}
    except Exception as e:
        log.warning("city-suggestions: lookup failed for %r (%s: %s)",
                    q, type(e).__name__, e)
        return {"success": True, "suggestions": []}
