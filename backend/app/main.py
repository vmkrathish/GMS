# ─────────────────────────────────────────────
# app/main.py — GMS FastAPI application entry
#
# Run (dev):   uvicorn app.main:app --reload --port 5001
# Docs:        http://localhost:5001/docs  (Swagger)
#              http://localhost:5001/redoc (ReDoc)
# ─────────────────────────────────────────────
import logging
import os
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core.config import settings

# Configured BEFORE the router imports below — without this,
# Python's default logging level (WARNING) silently drops every
# log.info(...) call anywhere in the app, including the Firebase
# initialization message in app/services/notify.py, which runs at
# MODULE IMPORT TIME (a top-level try/except) the moment the router
# imports below pull it in transitively. Getting this ordering wrong
# is exactly what happened here — the routers import must come
# AFTER this call, not before it.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

from app.routers import auth, bookings, chats, geo, notifications, services, users  # noqa: E402
from app.core import env_config as _env_config  # noqa: E402
from app.database.session import engine as _db_engine  # noqa: E402
from app.services import notify as _notify  # noqa: E402
from sqlalchemy import exc as _sa_exc, text  # noqa: E402
from sqlalchemy.engine import make_url as _make_url  # noqa: E402

# Which database are we on? Logged without the password, so a Render
# log tells you at a glance whether the env var was picked up.
_db = _make_url(settings.DATABASE_URL)
logging.getLogger("gms.startup").info(
    "Database: %s@%s/%s (mode=%s, source=%s)",
    _db.username, _db.host, _db.database,
    "ONLINE" if _env_config.IS_ONLINE else "LOCAL",
    _env_config.DATABASE_URL_SOURCE,
)

app = FastAPI(
    title=settings.APP_NAME,
    version="1.0.0",
    description="GMS (Get My Service) — service marketplace API. "
                "Two-step booking verification, dual-role users, "
                "self-growing search suggestions.",
)

# Serve uploaded avatars. MVP local storage — swap for Cloudinary
# (master plan Step 6) later without changing the API contract:
# both return a URL that gets stored in users.avatar_url.
STATIC_DIR = Path(__file__).parent / "static"
(STATIC_DIR / "avatars").mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

# Errors are turned into JSON HERE, inside the CORS middleware (it is
# added below, so it wraps this one). FastAPI's catch-all
# @exception_handler(Exception) runs OUTSIDE CORS: its 500 reached the
# browser without Access-Control-Allow-Origin, the browser hid it as a
# network error, and the web app said "check your connection" while the
# real problem was the database (e.g. Render's wrong DATABASE_URL
# password). Database connection failures are answered with 503.
_err_log = logging.getLogger("gms.errors")


def _db_error_kind(exc: BaseException) -> str:
    """Short, secret-free category of a database connection error."""
    m = str(getattr(exc, "orig", exc) or exc).lower()
    if "password authentication failed" in m:
        return "auth_failed"
    if "tenant or user not found" in m:
        return "tenant_not_found"
    if ("could not translate host" in m or "name or service not known" in m
            or "nodename nor servname" in m):
        return "dns"
    if "network is unreachable" in m or "connection refused" in m:
        return "network"
    if "timeout" in m or "timed out" in m:
        return "timeout"
    return "error"


@app.middleware("http")
async def _errors_inside_cors(request: Request, call_next):
    try:
        return await call_next(request)
    except (_sa_exc.OperationalError, _sa_exc.InterfaceError) as exc:
        _err_log.error("database unavailable on %s %s (%s)", request.method,
                       request.url.path, _db_error_kind(exc))
        return JSONResponse(status_code=503, content={
            "success": False,
            "message": "The GMS database is unavailable right now. "
                       "Please try again in a few minutes."})
    except Exception:  # noqa: BLE001
        _err_log.exception("unhandled error on %s %s", request.method,
                           request.url.path)
        return JSONResponse(status_code=500,
                            content={"success": False, "message": "Server error."})


# CORS — Flutter web/dev origins. Tighten FRONTEND_URL in production.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if settings.FRONTEND_URL == "*" else [settings.FRONTEND_URL],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Error shape parity with the legacy backend: {success, message}
@app.exception_handler(StarletteHTTPException)
async def http_exc(_: Request, exc: StarletteHTTPException):
    return JSONResponse(status_code=exc.status_code,
                        content={"success": False, "message": str(exc.detail)})


@app.exception_handler(RequestValidationError)
async def validation_exc(_: Request, exc: RequestValidationError):
    return JSONResponse(status_code=400,
                        content={"success": False,
                                 "message": "Invalid request data.",
                                 "errors": exc.errors()})


@app.exception_handler(Exception)
async def unhandled_exc(_: Request, exc: Exception):
    return JSONResponse(status_code=500,
                        content={"success": False, "message": "Server error."})


@app.get("/health", tags=["Health"])
def health(db: int = 0):
    out = {"success": True, "message": "GMS API is running",
           "env": settings.ENV,
           "time": datetime.now(timezone.utc).isoformat(),
           # False = no Firebase Admin credential on this server, so no
           # push is ever sent (history still works). Safe to expose: a
           # boolean, no path or secret.
           "push": _notify.push_enabled()}
    # /health?db=1 — called by the app while the login screen is open
    # (ApiService.warmUp): wakes a sleeping instance AND opens a pooled
    # database connection before the user taps Sign In, so the login
    # request itself doesn't pay for either. Plain /health is unchanged
    # and never touches the database.
    if db:
        t = time.perf_counter()
        try:
            with _db_engine.connect() as conn:
                conn.execute(text("SELECT 1"))
                # Read-only catalog check: has backend/sql/
                # add_push_reliability.sql been applied to THIS database?
                # Without it chat/booking writes lose retry-duplicate
                # protection (they still work — idempotency.py falls back).
                out["push_reliability_migration"] = bool(conn.execute(text(
                    "SELECT to_regclass('public.idempotency_keys') IS NOT NULL "
                    "AND to_regclass('public.uq_push_active_user_device') IS NOT NULL"
                )).scalar())
            out["db"] = "ok"
        except Exception as exc:  # noqa: BLE001
            out["db"] = "unavailable"
            # auth_failed / tenant_not_found / dns / network / timeout /
            # error — tells you which Render setting is wrong, no secrets.
            out["db_error"] = _db_error_kind(exc)
        out["db_ms"] = round((time.perf_counter() - t) * 1000, 1)
    return out


def _warm_db_pool() -> None:
    # Five connections (= SQLAlchemy's default pool_size), not one: right after login the app fires ~5
    # requests at once (home data, badges, unread count, push token). On
    # a cold pool each of those would open its own connection to
    # Supabase (TCP + TLS + auth, several round trips) — that burst was
    # the slowest part of "log in and see the home screen".
    log = logging.getLogger("gms.startup")
    want = max(1, int(os.getenv("GMS_DB_WARMUP_CONNECTIONS", "5")))
    conns = []
    t = time.perf_counter()
    try:
        for _ in range(want):
            c = _db_engine.connect()
            conns.append(c)
            c.execute(text("SELECT 1"))
        log.info("Database pool warmed: %d connection(s) in %.0f ms",
                 len(conns), (time.perf_counter() - t) * 1000)
    except Exception as exc:  # noqa: BLE001 — never block or crash startup
        log.warning("DB warm-up failed after %d connection(s): %s", len(conns), exc)
    finally:
        for c in conns:
            c.close()   # back to the pool, kept open for the next requests


# Open the first database connection in the background at startup, so
# the first request after a deploy / free-tier wake-up doesn't pay the
# TLS + auth handshake to Supabase. GMS_DB_WARMUP=0 disables it (tests).
if os.getenv("GMS_DB_WARMUP", "1") != "0":
    threading.Thread(target=_warm_db_pool, name="db-warmup", daemon=True).start()


@app.get("/meta/current-year", tags=["Health"])
def current_year():
    # Deliberately server-side — a phone's local clock can be set
    # wrong (or wrong on purpose), but Render's server clock is
    # NTP-synced cloud infrastructure. Anything that needs to show
    # "the actual current year" (like a copyright range) should read
    # from here, not from the device.
    return {"success": True, "year": datetime.now(timezone.utc).year}


for r in (auth, users, services, bookings, chats, notifications, geo):
    app.include_router(r.router)
