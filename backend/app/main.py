# ─────────────────────────────────────────────
# app/main.py — GMS FastAPI application entry
#
# Run (dev):   uvicorn app.main:app --reload --port 5001
# Docs:        http://localhost:5001/docs  (Swagger)
#              http://localhost:5001/redoc (ReDoc)
# ─────────────────────────────────────────────
import logging
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
def health():
    return {"success": True, "message": "GMS API is running",
            "env": settings.ENV,
            "time": datetime.now(timezone.utc).isoformat()}


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
