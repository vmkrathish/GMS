# GMS — Frontend + Backend (Integrated Build)

## What changed in this build

### 🔐 Security (IMPORTANT — read first)
- Real `.env` and the Firebase service-account JSON were **removed** from the repo.
  The old key `gms-project-1816.json` was exposed earlier — **revoke it** in
  Firebase Console → Project Settings → Service Accounts, generate a new key,
  and place it at `gms_backend/secrets/firebase-service-account.json` (git-ignored).
- Copy `gms_backend/.env.example` → `.env` and fill fresh credentials
  (new DB password + new JWT secret).
- `.gitignore` now blocks env files and service-account JSONs.
- Server boots even without the Firebase key (OTP endpoints return 503 until configured).

### 🔌 Full API layer (Flutter ⇄ Node)
Every backend endpoint now has a typed Dart method:

| Dart file (lib/core/api/) | Backend routes covered |
|---|---|
| `auth_api.dart`         | POST /auth/verify-otp, /auth/register |
| `user_api.dart`         | GET/PUT /users/me, PUT /users/fcm, GET /users/:id |
| `service_api.dart`      | GET /services/categories, GET+POST /services/suggestions, CRUD /services |
| `booking_api.dart`      | POST /bookings, GET /mine, GET /received, GET /:id, PUT /:id/status |
| `notification_api.dart` | GET /notifications, PUT read/read-all, DELETE /:id |

`core/services/api_service.dart` handles JWT (auto-saved on login),
15s timeout, one retry, and returns a typed `ApiResult`.
`core/config/api_config.dart` — set your LAN IP once; base URL is now `/api` root (was broken before).

### 🏠 Home screen (rebuilt)
- **Categories** fetched live from `GET /api/services/categories` with emoji chips;
  falls back to a bundled taxonomy (`core/data/default_categories.dart`) with an
  "offline" badge when the API/DB isn't reachable — records appear automatically
  once you connect the database.
- **Smart search**: debounced autocomplete from `GET /api/services/suggestions?q=`.
  Selecting/submitting a term calls `POST /api/services/suggestions`, so **new
  service names typed by users are added to the shared suggestion list** and
  popular terms rank higher (self-growing taxonomy).
- Tap a category chip → filters provider results by category.
- Pull-to-refresh, empty states, polished cards — same blue/white GMS theme.

### 🗄️ Database additions (run when you set up MySQL next)
```bash
mysql -u root -p < gms_backend/sql/schema.sql          # tables (+ search_terms, emoji col)
mysql -u root -p gms_db < gms_backend/sql/seed_categories.sql   # 40 categories + terms
# or richer seed via the data pipeline:
cd gms_backend && node scripts/fetch_categories.js
```

## Run
```bash
# Backend
cd gms_backend
npm install
cp .env.example .env   # fill values
npm run dev            # http://localhost:5001/health

# Frontend
cd gms_frontend
flutter pub get
flutter run -d chrome
```

## Wiring the remaining screens (5-minute pattern each)
The API layer is complete; screens just call it. Examples:

```dart
// bookings_screen.dart
final res = await BookingApi.getMyBookings();
if (res.success) { bookings = res.data['bookings'] ?? res.data; }

// notifications_screen.dart
final res = await NotificationApi.getNotifications();

// you_screen.dart (profile)
final res = await UserApi.getMe();
```
Follow home_screen.dart as the reference implementation
(loading flag → API call → fallback → setState).

---

## 🔑 Auth Flow (added in this build)

**Flow:** Splash (2.2s) → session check → already logged in? → **Home**. Not logged in? → **Sign In**.

- **Sign In** (`auth/login_screen.dart`) — one smart field: phone number OR email.
  Unknown identifier → redirected to Sign Up with the field pre-filled.
- **Sign Up** (`auth/signup_screen.dart`) — basics only: name, phone, email.
  Everything else is completed later from the You/Profile tab.
- **Session** (`core/services/session_manager.dart`) — JWT + user profile in
  SharedPreferences; drawer header greets the user by name; **Logout** in the
  drawer clears the session and returns to Sign In.
- **Backend:** `POST /api/auth/signup` and `POST /api/auth/login` added
  (validation + duplicate check + JWT). These are OTP-less for MVP —
  the Firebase `verify-otp` path stays in place as the production upgrade.
- **Demo mode:** if the backend is unreachable, the Sign In screen shows a
  dev-only "Continue in demo mode" link so UI can be tested before MySQL is
  connected. Remove before release.
- **DB note for next chat:** `users` table now has an `email` column
  (migration included at the bottom of `schema.sql`).


---

## 🗄️ v4 — Full MySQL Wiring (this build)

### One-command database rebuild (DESTRUCTIVE — recreates gms_db)
```bash
mysql -u root -p < gms_backend/sql/gms_full_setup.sql
```
Creates all 8 tables (users, service_categories, services, bookings,
notifications, search_terms, reviews, messages) and seeds dummy data:
14 users (the dev team names), 40 emoji categories, 18 services,
15 bookings in every status, 6 reviews, 4 chat threads, notifications,
and ~90 search terms.

**Test sign-in with any seeded account**, e.g.
phone `9000000001` (Rathish, provider) or `9000000011` (Anirudh, customer),
or emails like `rathish@gms.dev`.

### Screens now fully connected
- **Home** — live categories, suggestions, recommendations + NEW: tap any
  provider card → booking sheet (schedule now/later, address, notes) → creates
  a real booking + push notification to the provider.
- **You (Profile)** — live profile from /users/me, edit name/city, and
  **Provider Mode**: your service listings + "Add Service" sheet. Creating a
  listing is how any user becomes a provider (dual-role). Old 3,423-line
  static screen replaced by a 550-line connected version.
- **Bookings** — two tabs: *My Bookings* (seeker side) and *Received*
  (provider side) with Accept / Reject / Start / Complete / Cancel actions
  and a Chat shortcut to the other party.
- **History** — completed + cancelled bookings merged from both roles, with
  All/Completed/Cancelled filters and Booked/Provided tags.
- **Chat** — real conversations: list with unread badges → thread view with
  bubbles, 5-second polling, send via POST /api/chats/:userId.

### Backend fixes in this build
- `getServices` rewritten (was querying non-existent tables) — now includes
  ratings from the reviews table, plus q/category/city/provider filters.
- Dual-role unblocked: role gates removed from createBooking,
  getReceivedBookings and createService; self-booking prevented.
- `scheduled_at` optional (defaults to now) for "as soon as possible" bookings.
- New: chat endpoints (GET /api/chats, GET+POST /api/chats/:userId),
  reviews + messages tables, avatar_url/bio columns on users.


---

## 🔁 v5 — Original You Page Restored + Full Profile DB

- The original You-page design is **fully restored** (profile card with
  tappable avatar viewer, primary + other services with search field,
  View/Edit service dialogs, rating, dial-code phone, email, live location
  line, compact full address, Edit Profile screen with 1:1 aspect-ratio
  image cropping, OTP field, address details card, and the map-based
  Location Picker with draggable pin).
- Underneath, it is now DATABASE-CONNECTED while keeping the same
  ValueNotifier architecture: profile loads from GET /users/me on open,
  Save Changes pushes the full model (name, email, dial code, location,
  address line 1, area/street/village, landmark, pincode, city, state,
  country, latitude, longitude) via PUT /users/me, and the Edit Service
  dialog syncs primary + other services to the services table
  (is_primary column, single-primary rule enforced server-side).
- The service search field now uses the live suggestion engine
  (falls back to the built-in list offline).
- Database regenerated: users table carries the complete You-page address
  model + coordinates; seed users have full Tamil Nadu addresses with
  lat/lng. Run: `mysql -u root -p < gms_backend/sql/gms_full_setup.sql`
- The whole flow was TESTED against a real MySQL server: login, getMe,
  updateMe (address + coordinates), services with is_primary, suggestion
  search, and primary-service switching — all verified working.
- `gms_backend/.env` is pre-filled with the local DB password so the
  server connects immediately (local dev only — never commit this file).


---

## 🔧 v6 — Fixes + Original Booking Flows + Rich Data

**Fixed:**
1. Edit Profile crash (DropdownButton assertion) — DB state 'Tamil Nadu' vs
   UPPERCASE dropdown items; state is now normalized on load and the value is
   validated against the items list before the dropdown builds.
2. Duplicate accounts — phone numbers are now normalized ('+91 90000 00001',
   '09000000001' and '9000000001' are the SAME account) on signup AND login;
   duplicate email on profile edit returns a friendly 409 instead of crashing.

**Booking flows (original app vocabulary, DB-connected):**
- Statuses: Pending → Confirmed → Visiting → Completed, plus
  Reschedule Requested and Cancellation Request (+ Cancelled).
- Customer actions: Reschedule (date+time picker → new proposed time),
  Cancel (pending) / Request Cancellation (confirmed).
- Provider actions: Accept/Reject, Start Visit, Mark Completed,
  Approve New Time / Decline (reschedules),
  Approve Cancellation / Keep Booking (cancellation requests).
- Roles derive from the booking relationship (true dual-role) and
  reschedules carry the new scheduled_at to the database.
- Entire lifecycle TESTED live: request → approve → visit → complete,
  and cancellation-request → approval, with notifications generated.

**Data:** 36 bookings covering all 7 statuses on BOTH tabs for every user,
11 reviews, 25 chat messages (every user has at least one conversation),
16 notifications. Reseed with: mysql -u root -p < gms_backend/sql/gms_full_setup.sql


---

## 💳 v7 — Two-Step Booking Verification Workflow

**Core rule: provider approval alone NEVER confirms a booking.**
`pending → provider accepts (+ sets advance ₹) → awaiting_advance →
customer pays advance → confirmed → in_progress (Visiting) → completed`

- **Accept** (provider): dialog asks for advance amount + optional payment
  deadline (12/24/48h). Amount 0 = confirm without advance. Deadline passing
  auto-expires the booking (status `expired`).
- **Pay Advance** (customer): simulated payment for MVP → instantly
  `confirmed`, both sides notified. Real gateway (Razorpay) plugs into the
  same `pay_advance` action later.
- **Reject** (provider): reason is MANDATORY — preset reasons (not available /
  already booked / outside service area / personal) + custom. Customer sees
  the reason.
- **Unlimited reschedule negotiation**: provider `reschedule` (time + reason
  required) ⇄ customer `counter_proposal` — statuses flip between
  `reschedule_by_provider` / `reschedule_by_customer` with no iteration limit
  until accept / cancel / reject. Accepting a proposal locks the date and
  routes into the advance-payment step.
- **Timeline UI**: tap any booking card → bottom sheet with the full event
  history (who did what, when, reasons, proposed times, amounts) from the new
  `booking_events` table.
- **Statuses (11)**: pending, awaiting_advance, confirmed, in_progress,
  completed, reschedule_by_provider, reschedule_by_customer, rejected,
  cancelled_by_customer, cancelled_by_provider, expired.
- **API**: `PUT /api/bookings/:id/action` {action, reason?, proposed_time?,
  advance_amount?, payment_deadline?} + `GET /api/bookings/:id/events`.
  Old `/status` route still works as a shim.
- Every action has a confirmation dialog; notifications fire on every event.
- **Live-tested**: two-step flow (start blocked before payment ✅),
  mandatory rejection reason ✅, 4-round negotiation → agreement → advance →
  confirmed ✅, timeline ✅, expiry ✅.
- DB password vmk@1819 locked in `.env` and `.env.example`.
