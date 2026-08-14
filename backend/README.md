# GMS Backend — FastAPI

## Structure
```
app/
├── main.py        FastAPI app, CORS, error handlers (legacy-compatible shapes)
├── core/          config (pydantic-settings), JWT security
├── database/      engine, SessionLocal, get_db dependency
├── models/        SQLAlchemy ORM — all 9 tables
├── schemas/       Pydantic request models
├── routers/       auth, users, services, bookings, chats, notifications
├── services/      booking_engine (two-step workflow), notify (DB + FCM)
├── middleware/    get_current_user auth dependency
└── utils/         phone normalization, serialization helpers
alembic/           migrations (baseline stamped)
sql/               gms_full_setup.sql — full DB rebuild + demo data
tests/
```

## Run
```bash
pip install -r requirements.txt
uvicorn app.main:app --reload --port 5001
```
Docs: /docs (Swagger) · /redoc

## Booking workflow engine
pending → accept(+advance) → awaiting_advance → pay_advance → confirmed
→ start (Visiting) → complete. Reject needs a reason. Reschedule ⇄
counter-proposal loop is unlimited. Deadline passing → expired.
`PUT /api/bookings/{id}/action` — see services/booking_engine.py.

## Note on DATABASE_URL
Special characters in the password must be URL-encoded:
`vmk@1819` → `vmk%401819` (@ becomes %40).
