# GMS — Get My Service 🛠️

**© 2026 M K Rathish. All Rights Reserved.**
This is proprietary software — not open source. See [`LICENSE`](./LICENSE)
before viewing, running, or referencing any part of this project.

A dual-role local service marketplace: one app where anyone can **book**
services or **provide** them — no separate customer/provider apps, switch
roles anytime from your profile. Think Amazon/Flipkart (broad marketplace)
+ Swiggy/Zomato (on-demand booking) + Rapido (live location-based
discovery), combined.

## Highlights

- **Real password authentication** — bcrypt-hashed, live inline validation
  on Change Password (checks your current password as you type, rejects a
  new password identical to the current one), all wired through Settings.
- **Two-step booking verification** — provider acceptance alone never
  confirms a booking; an advance payment (simulated) is required, with
  unlimited reschedule negotiation between both sides and a full,
  guaranteed-complete timeline on every booking.
- **Live discovery map** — GPS-verified, shows every active provider
  within 50km by default the moment you open it, Google-Maps-style search
  bar with live autocomplete and keyboard navigation (arrow keys + Enter),
  category-emoji markers, and "here's what IS nearby instead" suggestions
  when a specific search comes up empty.
- **Location-aware "Recommended for You"** — Home/Current toggle, strict
  nearest-to-farthest (KNN-style) ordering capped at 50km for on-site
  trades; remote-friendly work (web dev, design, editing…) stays
  unbounded since distance doesn't apply to it. You never see your own
  listings in your own search or recommendations.
- **Real driving directions, not just straight-line distance** — a
  Google-Maps-style route view (via OSRM) shown before booking anyone,
  with actual road distance, estimated drive time, and the route drawn
  on the map. Booking-card routes use the exact location saved at
  booking time, not a live re-fetch, so "where this booking actually
  happened" never silently drifts.
- **Real-time-ish chat** — presence ("Online now" / "Last seen X ago"),
  read receipts, WhatsApp-style day separators, unread-thread badge on
  the bottom nav.
- **Full-app refresh** — tap the logo to refresh whichever tab is open;
  re-tap the tab you're already on to reload just that screen, across
  all six tabs.
- Self-growing search suggestions, public profile pages, real photo
  uploads, and a full audit timeline on every booking.

## Monorepo layout
```
GMS/
├── frontend/   Flutter app (mobile + web) — 6-tab shell:
│               Home / Map / You / Payments / Bookings / Chat
├── backend/    FastAPI + SQLAlchemy + Alembic (installed, not yet used) + PostgreSQL
├── docs/       Architecture notes & full changelog
├── assets/     Design assets
└── README.md
```

## Quick start

### 1. Database (PostgreSQL — primary, Supabase-ready)
```bash
# local Postgres:
psql -U postgres -c "CREATE DATABASE gms_db;"
psql -U postgres -d gms_db -f backend/sql/gms_supabase_setup.sql

# or paste the same file into Supabase's SQL Editor for a hosted DB
```
This is a **full destructive rebuild** — see [Demo data](#demo-data) below
for what it seeds. The database backing this project is **PostgreSQL**,
not MySQL — every query in the backend was converted (portable haversine
distance math instead of MySQL-only functions, `ILIKE` instead of
`LIKE`, proper `TRUE`/`FALSE` booleans, no MySQL-only `IF()`/`DATE_SUB`).

> **Legacy**: `backend/sql/gms_full_setup.sql` is the old MySQL/MariaDB
> version, kept only for historical reference — the backend no longer
> targets it. Don't use it for a fresh setup.

### 2. Backend (FastAPI)
```bash
cd backend
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
# database connection lives in app/core/env_config.py's LOCAL/ONLINE
# switch (see the highlighted section at the top of this README) —
# NOT in .env. Point LOCAL_DATABASE_URL at your local Postgres, or
# flip to ONLINE and use your Supabase connection string.
cp .env.example .env        # only JWT_SECRET + other real secrets go here
uvicorn app.main:app --reload --port 5001
```
Swagger: http://localhost:5001/docs · ReDoc: http://localhost:5001/redoc

### 3. Frontend (Flutter)
```bash
cd frontend
flutter pub get
# confirm lib/core/config/api_config.dart is on the LOCAL switch (see
# the highlighted section at the very top of this README) and your
# LAN IP is correct there (for a physical device)
flutter run -d chrome
```

## Demo data

The seed data is built directly from a user-provided reference list of
100 real named people, their actual places (spread across Tamil Nadu —
small towns like Sankagiri and Anthiyur through major cities like
Chennai, Coimbatore, and Madurai), phone numbers, and the services each
of them actually offers.

| | |
|---|---|
| Users | 100 — every one a real name/place/phone from the reference list |
| Categories | 41, spanning on-site trades and remote-friendly work |
| Services | 153 — primary + secondary listings mapped from each person's stated services |
| Bookings | 153, spanning **every one of the 11 workflow statuses** |
| Timeline events | 629 — **every single booking has a complete, status-matched event trail** (verified by a built-in `SELECT ... bookings_missing_timeline` check at the end of the seed file, which must return 0) |
| Reviews / Messages / Notifications | 45 / 248 / 110 |

Sign in with phone `9000000001` (Rathish) through `9000000100` (Fazil),
or any generated email like `rathish@gmail.com`. **Every account's
default password is `1819`** — change it anytime via Settings → Change
Password.

## Core architecture

- **Auth**: JWT + bcrypt password hashing, phone/email login, phone
  numbers normalized to a canonical 10-digit form regardless of
  `+91`/leading-zero/spacing. `POST /api/auth/verify-password` powers
  live inline validation on the Change Password screen without any
  side effects.
- **Booking engine**: 11 statuses (`pending` → `awaiting_advance` →
  `confirmed` → `in_progress` → `completed`, plus reschedule negotiation,
  rejection, cancellation, and expiry paths), 9 actions via
  `PUT /api/bookings/{id}/action`. Every action writes an entry to
  `booking_events` — tap any booking card in the app for the full
  timeline. Booking creation saves the customer's location at that exact
  moment (Home / Pinned / Current GPS, whichever was selected) — this
  saved point is what booking-card routes use later, never a live
  re-fetch, so it always reflects where the booking actually happened.
- **Media**: uploaded avatars are stored as **relative paths**
  (`/static/avatars/x.png`), never a host-baked absolute URL — this is
  what lets photos keep working across different dev machines, WiFi
  networks, ports, or a future real deployment. The client resolves the
  full URL against whatever host it's currently talking to
  (`ApiConfig.resolveMediaUrl()`).
- **Location & routing**: `users.latitude/longitude` (set via the
  profile's map picker) is the "Home" location used throughout the app.
  Reverse geocoding goes through the backend (`GET /api/geo/reverse` →
  OpenStreetMap Nominatim) rather than a client-side plugin, since
  Flutter's `geocoding` package has no Web implementation. Real driving
  directions — distance, estimated time, and the route line — come from
  `GET /api/geo/route`, proxying OSRM.
- **Geospatial search**: a portable haversine (great-circle) formula
  computes real distance directly on the `latitude`/`longitude` DECIMAL
  columns — plain SQL math (`ACOS`/`COS`/`SIN`/`RADIANS`), no
  database-specific geospatial functions or GEOMETRY column types
  needed. The map's default view (no search yet) and "Recommended for
  You" both use this; you're always excluded from your own results.
- **Cross-screen refresh**: a small `RefreshBus` (`ValueNotifier`-based
  signals per tab) lets the logo tap or a re-tap of the active nav tab
  reload that screen's data fresh from the database, without needing a
  full app restart.

## Known limitations / honest notes

- No deployment yet (Oracle Cloud Always Free is the target — see
  `docs/CHANGELOG.md` for the roadmap), no Cloudinary (local file
  storage, though already portable), no Alembic in active use (manual
  SQL migrations only), no real payment gateway, OTP disabled, no
  automated tests, no CI/CD, no Docker, no WebSocket chat (still 5s
  polling), no dark mode or additional languages yet (Settings shows
  both as fixed for now, with a "more coming soon" note).
- Driving-route calls depend on OSRM's public routing service being
  reachable from wherever the app is running — if it isn't, the route
  screen falls back to straight-line distance rather than failing
  outright.

## Migrations (Alembic)
Installed but not yet the primary migration path — schema changes are
currently applied via the full `gms_supabase_setup.sql` reseed or
standalone point-migration `.sql` files in `backend/sql/`. Alembic
adoption is on the roadmap (see `docs/CHANGELOG.md`).
```bash
cd backend
alembic revision --autogenerate -m "describe change"
alembic upgrade head
```

## Deployment target
Supabase (PostgreSQL + Storage, once avatar uploads move off local disk)
for the database, Render for the FastAPI backend — both free-tier for
MVP/testing. GitHub as the master repo (frontend + backend + docs +
assets, no secrets/.env/build files committed). Flutter builds to
Android/iOS APK/AAB against the Render API URL; Flutter Web hosting is
optional and only needed for browser access. Not yet deployed — see
`docs/CHANGELOG.md` for the full step-by-step plan.

## Full history
`docs/CHANGELOG.md` has the complete, verbose version history of every
feature and bug fix across this project — from the original Node.js →
FastAPI migration through the live map, location-aware recommendations,
password authentication, real driving routes, and everything else
summarized above. For a dense, AI-readable summary of the whole project
(architecture, schema, lessons learned, roadmap), see the project
capsule if one has been generated for this repo.

## License & Copyright

**© 2026 M K Rathish. All Rights Reserved.**

This is **not** open-source software. No license is granted to use,
copy, modify, distribute, or study this code for any purpose —
commercial, personal, or educational — without prior written
permission from the copyright holder. See the [`LICENSE`](./LICENSE)
file for the full terms.

This project is intended for patent protection by the copyright
holder; its public visibility (if any) does not waive any current or
future intellectual property rights.
