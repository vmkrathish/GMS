<div align="center">

<img src="./frontend/assets/images/gms_logo.png" alt="GMS Logo" width="120" />

# GMS — Get My Service

Flutter · FastAPI · PostgreSQL Service Marketplace

![Status](https://img.shields.io/badge/Status-In%20Development-yellow)
![License](https://img.shields.io/badge/License-Proprietary-lightgrey)
![Last Commit](https://img.shields.io/github/last-commit/vmkrathish/GMS)


</div>

---

**Proprietary Software — ©️ 2026 M K Rathish. All Rights Reserved.**
Not open source. See [`LICENSE`](./LICENSE) before viewing, running, or referencing any part of this project.

## About

GMS (Get My Service) is a dual-role, location-aware service marketplace: any user can book a service or offer one, switching roles within the same account at any time. It draws on established patterns from Amazon/Flipkart-style marketplaces, Swiggy/Zomato-style two-step booking confirmation, and Rapido-style live, GPS-verified discovery — combined into a single, focused product for local, on-demand services.

The platform's core differentiator is genuine geospatial accuracy: discovery and recommendations are computed from real GPS coordinates rather than static text-based locations, and routing reflects actual road distance and drive time via OSRM rather than straight-line approximation.

**Stack**: Flutter (Android, iOS, Web) · FastAPI · PostgreSQL (Supabase) · OSRM · Firebase Cloud Messaging · JWT + bcrypt

## Key Features

- **Real authentication** — bcrypt-hashed passwords, live inline validation on password change
- **Two-step booking verification** — provider acceptance plus a required advance payment (simulated); unlimited reschedule negotiation; full booking timeline
- **Live discovery map** — GPS-verified, shows active providers within 50km by default, autocomplete search with keyboard navigation, category-emoji markers, nearby-alternative suggestions on empty results
- **Location-aware recommendations** — Home/Current toggle, nearest-to-farthest (KNN-style) ordering capped at 50km for on-site trades; remote-friendly work stays unbounded
- **Real driving directions** — Google-Maps-style route view via OSRM, with road distance, drive time, and route drawn on the map; booking-card routes always reflect the location saved at booking time
- **Real-time-ish chat** — presence indicators, read receipts, day separators, unread badge
- **Full-app refresh** — tap the logo to refresh the current tab; re-tap the active tab to reload it
- Self-growing search suggestions, public profile pages, real photo uploads, full booking audit timeline

## Tech Stack

**Languages**

![Python](https://img.shields.io/badge/-Python-3776AB?style=flat-square&logo=python&logoColor=white)
![Dart](https://img.shields.io/badge/-Dart-0175C2?style=flat-square&logo=dart&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/-PostgreSQL-4169E1?style=flat-square&logo=postgresql&logoColor=white)

**Mobile & Frontend**

![Flutter](https://img.shields.io/badge/-Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)
![Android](https://img.shields.io/badge/-Android-3DDC84?style=flat-square&logo=android&logoColor=white)

**Backend & APIs**

![FastAPI](https://img.shields.io/badge/-FastAPI-009688?style=flat-square&logo=fastapi&logoColor=white)
![SQLAlchemy](https://img.shields.io/badge/-SQLAlchemy-D71F00?style=flat-square&logo=python&logoColor=white)
![JWT](https://img.shields.io/badge/-JWT-000000?style=flat-square&logo=jsonwebtokens&logoColor=white)
![OSRM](https://img.shields.io/badge/-OSRM-6E4C13?style=flat-square)

**Database**

![PostgreSQL](https://img.shields.io/badge/-PostgreSQL-4169E1?style=flat-square&logo=postgresql&logoColor=white)
![Supabase](https://img.shields.io/badge/-Supabase-3FCF8E?style=flat-square&logo=supabase&logoColor=white)

**DevTools**

![Git](https://img.shields.io/badge/-Git-F05032?style=flat-square&logo=git&logoColor=white)
![GitHub](https://img.shields.io/badge/-GitHub-181717?style=flat-square&logo=github&logoColor=white)
![VS Code](https://img.shields.io/badge/-VS%20Code-007ACC?style=flat-square&logo=visualstudiocode&logoColor=white)
![Render](https://img.shields.io/badge/-Render-46E3B7?style=flat-square&logo=render&logoColor=white)

## Project Structure

```
GMS/
├── assets/
│   └── logo.png       App/README logo
├── backend/            FastAPI + SQLAlchemy + Alembic + PostgreSQL
├── docs/
│   ├── CHANGELOG.md         Current changelog
│   └── CHANGELOG_v1-v7.md   Full version history archive
├── frontend/           Flutter app — 6-tab shell: Home / Map / You / Payments / Bookings / Chat
├── .gitignore
├── LICENSE
└── README.md
```

## Getting Started

### 1. Database (PostgreSQL — primary, Supabase-ready)

```bash
psql -U postgres -c "CREATE DATABASE gms_db;"
psql -U postgres -d gms_db -f backend/sql/gms_supabase_setup.sql
```

This is a **full destructive rebuild** — see [Demo Data](#demo-data) for what it seeds. The backend targets **PostgreSQL** only (portable haversine distance math, `ILIKE`, native booleans — no MySQL-only functions).

> `backend/sql/gms_full_setup.sql` is the legacy MySQL/MariaDB version, kept for historical reference only. Do not use it for a fresh setup.

### 2. Backend (FastAPI)

```bash
cd backend
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # JWT_SECRET and other real secrets only
uvicorn app.main:app --reload --port 5001
```

Database connection lives in `app/core/env_config.py` (LOCAL/ONLINE switch), not `.env`.

- Swagger: `http://localhost:5001/docs`
- ReDoc: `http://localhost:5001/redoc`

### 3. Frontend (Flutter)

```bash
cd frontend
flutter pub get
flutter run -d chrome
```

Confirm `lib/core/config/api_config.dart` is on the LOCAL switch and your LAN IP is correct there for a physical device.

## Demo Data

| | Count |
|---|---|
| Users | 100 |
| Categories | 41 |
| Services | 153 |
| Bookings | 153 (every one of the 11 workflow statuses) |
| Timeline events | 629 (every booking has a complete, status-matched trail) |
| Reviews / Messages / Notifications | 45 / 248 / 110 |

Sign in with phone `9000000001` (Rathish) through `9000000100` (Fazil), or any generated email like `rathish@gmail.com`. **Default password for every account is `1819`** — change it via Settings → Change Password.

## Core Architecture

- **Auth**: JWT + bcrypt, phone/email login, phone numbers normalized to a canonical 10-digit form. `POST /api/auth/verify-password` powers live inline validation without side effects.
- **Booking Engine**: 11 statuses (`pending` → `awaiting_advance` → `confirmed` → `in_progress` → `completed`, plus reschedule, rejection, cancellation, and expiry paths), 9 actions via `PUT /api/bookings/{id}/action`. Every action writes to `booking_events` for a full per-booking timeline.
- **Media**: Uploaded avatars stored as relative paths (`/static/avatars/x.png`), resolved client-side via `ApiConfig.resolveMediaUrl()` — keeps photos working across dev machines, networks, and future deployments.
- **Location & Routing**: `users.latitude/longitude` is the "Home" location. Reverse geocoding runs through the backend (`GET /api/geo/reverse` → Nominatim). Driving directions come from `GET /api/geo/route`, proxying OSRM.
- **Geospatial Search**: A portable haversine formula computes distance directly on `latitude`/`longitude` DECIMAL columns — no database-specific geospatial functions needed.
- **Cross-Screen Refresh**: A small `RefreshBus` (`ValueNotifier`-based) lets a logo tap or active-tab re-tap reload that screen's data without a full app restart.

## API Reference

- Swagger UI: `http://localhost:5001/docs`
- ReDoc: `http://localhost:5001/redoc`

## Migrations (Alembic)

Installed but not yet the primary migration path — schema changes are currently applied via the full `gms_supabase_setup.sql` reseed or standalone `.sql` files in `backend/sql/`.

```bash
cd backend
alembic revision --autogenerate -m "describe change"
alembic upgrade head
```

## Deployment Target

- **Database**: Supabase (PostgreSQL + Storage)
- **Backend**: Render (FastAPI), free tier for MVP/testing
- **Frontend**: Flutter builds to Android/iOS APK/AAB against the Render API URL; Flutter Web hosting optional

Not yet deployed — see `docs/CHANGELOG.md` for the full plan.

## Known Limitations

- No deployment yet, no Cloudinary (local file storage, already portable)
- No Alembic in active use (manual SQL migrations only)
- No real payment gateway, OTP disabled
- No automated tests, CI/CD, or Docker
- No WebSocket chat (5s polling)
- No dark mode or additional languages yet
- Driving-route calls depend on OSRM's public service; falls back to straight-line distance if unreachable

## Roadmap

See `docs/CHANGELOG.md` for the complete version history — from the original Node.js → FastAPI migration through the live map, location-aware recommendations, and real driving routes.

---

## License & Copyright

**©️ 2026 M K Rathish. All Rights Reserved.**

This is **not** open-source software. No license is granted to use, copy, modify, distribute, or study this code for any purpose — commercial, personal, or educational — without prior written permission from the copyright holder. See the [`LICENSE`](./LICENSE) file for full terms.
