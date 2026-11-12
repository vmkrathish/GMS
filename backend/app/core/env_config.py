# ═══════════════════════════════════════════════════════════
#  BACKUP NOTE (added when this archive was made): the two database
#  passwords and the Supabase project ref below were REPLACED with
#  <PLACEHOLDERS> so no credential ships in the backup. Fill them in
#  locally, or — better — stop hardcoding them: read DATABASE_URL from
#  an environment variable. IS_ONLINE is shown as True because that is
#  the state committed on the owner's machine (2026-09-02, commit
#  b222352); set it to False for local development.
# ═══════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════
#  app/core/env_config.py — THE ONE PLACE to switch the GMS
#  backend between LOCAL (running on your own laptop) and
#  ONLINE (hosted, e.g. Render/Railway) mode.
#
#  Both LOCAL and ONLINE now point at PostgreSQL — MySQL/MariaDB
#  is no longer used anywhere in this project.
#
#  HOW TO USE — flip the ONE line marked "THE SWITCH" below:
#    Developing locally  → IS_ONLINE = False  (already set)
#    Ready to deploy      → set IS_ONLINE = True, and make sure
#                           ONLINE_DATABASE_URL and
#                           ONLINE_FRONTEND_URL below are your
#                           real hosted database and deployed
#                           frontend's address, save, push.
#
#  core/config.py reads its defaults from THIS file — nothing
#  else in the backend should ever hardcode a database URL or
#  an allowed-origin URL. Change it here once, it's reflected
#  everywhere (CORS, the database connection) automatically.
#
#  ⚠️  THIS FILE ONLY AFFECTS A BACKEND RUNNING ON *THIS* MACHINE.
#  Flipping this switch does NOT deploy anything, does NOT touch
#  Render, and does NOT affect the separate copy of this file
#  already running on Render (which only updates when you push to
#  GitHub and Render redeploys). If you just want your local Flutter
#  app to talk to your already-deployed Render backend, you do NOT
#  need to touch this file or run uvicorn locally at all — flip
#  frontend/lib/core/config/api_config.dart's _isOnline instead. Only
#  flip THIS switch to True if you are intentionally running a
#  backend on your own laptop that should connect to the real
#  Supabase database (an advanced case — also update
#  ONLINE_FRONTEND_URL below to match your local Flutter dev origin,
#  or CORS will reject it, exactly like it did the first time this
#  mix-up happened).
# ═══════════════════════════════════════════════════════════

# ─────────────────────────────────────────────
# 🔀 THE SWITCH
# ─────────────────────────────────────────────
# IS_ONLINE = False  # ← LOCAL (dev on your laptop)
IS_ONLINE = True  # ← ONLINE (hosted, e.g. Render) — uncomment this,
#                      comment the line above, when deploying.

# ─────────────────────────────────────────────
# 🏠 LOCAL values — used when IS_ONLINE = False
# Assumes a local PostgreSQL install with a "gms_db" database and
# the default "postgres" user — adjust to match your own machine
# if you set it up differently (see README.md's Quick Start).
# ─────────────────────────────────────────────
LOCAL_DATABASE_URL = "postgresql+psycopg2://postgres:<LOCAL_DB_PASSWORD>@localhost:5432/gms_db"
LOCAL_FRONTEND_URL = "*"  # allow any origin during local dev (Flutter web/emulator/device)

# ─────────────────────────────────────────────
# 🌍 ONLINE values — used when IS_ONLINE = True
# This is Supabase's "pooler" (Supavisor) connection string, NOT the
# "Direct connection" one — this matters, this is not just a style
# choice:
#
# Supabase's Direct connection (host: db.<project-ref>.supabase.co)
# resolves over IPv6 by default. Render's free tier has no outbound
# IPv6 support, so a Direct connection fails there with
# "Network is unreachable" even though the credentials are completely
# correct — this is exactly the bug that caused this deploy to fail.
# The pooler (host: aws-0-<region>.pooler.supabase.com, username
# postgres.<project-ref>) runs over IPv4 and works correctly on
# Render and most other free-tier hosts. Get this exact string from
# Supabase's dashboard: Project → Connect → look for the pooled
# connection option (sometimes labeled "Session pooler" or similar),
# not "Direct connection".
# ─────────────────────────────────────────────
# 🔐 The ONLINE password should NOT live in this file any more.
# Put the full pooler string in Render → your service → Environment →
# DATABASE_URL. That value is read below and wins over this line.
# This line is only a LEGACY FALLBACK for a machine where the env var
# isn't set yet; keep it as placeholders (it is ignored while it
# contains "<" … ">"). Either "postgresql://" or
# "postgresql+psycopg2://" works — the driver is added automatically.
ONLINE_DATABASE_URL = "postgresql+psycopg2://postgres.<SUPABASE_PROJECT_REF>:<SUPABASE_DB_PASSWORD>@aws-0-ap-northeast-2.pooler.supabase.com:5432/postgres"
ONLINE_FRONTEND_URL = "*"

# ─────────────────────────────────────────────
# Everything below derives from the switch above — don't hand-edit.
# ─────────────────────────────────────────────
import logging as _logging
import os as _os

_log = _logging.getLogger("gms.env_config")


def normalize_db_url(url: str) -> str:
    """Make sure SQLAlchemy uses psycopg2 (the driver we install).

    A bare "postgresql://" (what Supabase's dashboard copies) makes
    SQLAlchemy 2.1+ look for the *psycopg 3* driver, which is not
    installed → the app crashes at import. "postgres://" (Heroku-style)
    is not accepted by SQLAlchemy at all. Both are rewritten here.
    """
    url = url.strip()
    for prefix in ("postgresql://", "postgres://"):
        if url.startswith(prefix):
            return "postgresql+psycopg2://" + url[len(prefix):]
    return url


def _resolve_online_url() -> tuple[str, str]:
    """ONLINE mode: real environment variable first, file second.

    Only the process environment (Render's Environment tab, or an
    `export` in your shell) is consulted — NOT a .env file — so a
    forgotten .env can never silently redirect the database again.
    """
    env_url = _os.environ.get("DATABASE_URL", "").strip()
    if env_url:
        return normalize_db_url(env_url), "env:DATABASE_URL"
    if "<" in ONLINE_DATABASE_URL and ">" in ONLINE_DATABASE_URL:
        raise RuntimeError(
            "IS_ONLINE = True but no DATABASE_URL environment variable is set, "
            "and env_config.py's ONLINE_DATABASE_URL is still a placeholder. "
            "Set DATABASE_URL (Render → Environment) to the Supabase *pooler* "
            "connection string, or set IS_ONLINE = False for local development."
        )
    _log.warning(
        "DATABASE_URL env var not set — using the password hard-coded in "
        "env_config.py. Move it to the DATABASE_URL environment variable and "
        "put placeholders back in this file."
    )
    return normalize_db_url(ONLINE_DATABASE_URL), "env_config.py (legacy)"


if IS_ONLINE:
    DATABASE_URL, DATABASE_URL_SOURCE = _resolve_online_url()
else:
    DATABASE_URL, DATABASE_URL_SOURCE = normalize_db_url(LOCAL_DATABASE_URL), "env_config.py (LOCAL)"
FRONTEND_URL = ONLINE_FRONTEND_URL if IS_ONLINE else LOCAL_FRONTEND_URL
