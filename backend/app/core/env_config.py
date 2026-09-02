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
LOCAL_DATABASE_URL = "postgresql+psycopg2://postgres:vmk1819@localhost:5432/gms_db"
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
ONLINE_DATABASE_URL = "postgresql://postgres.qxjufkqyuuplguoaseiq:sasmi-gms1819@aws-0-ap-northeast-2.pooler.supabase.com:5432/postgres"
ONLINE_FRONTEND_URL = "*"

# ─────────────────────────────────────────────
# Everything below derives from the switch above — don't hand-edit.
# ─────────────────────────────────────────────
DATABASE_URL = ONLINE_DATABASE_URL if IS_ONLINE else LOCAL_DATABASE_URL
FRONTEND_URL = ONLINE_FRONTEND_URL if IS_ONLINE else LOCAL_FRONTEND_URL
