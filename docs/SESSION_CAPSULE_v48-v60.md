# GMS — Session Capsule (v48–v60)

**Covers:** Firebase Cloud Messaging, real-time chat delivery states, platform-controlled pricing & reviews, four concrete bug fixes, full database regeneration with real data, README refactor, and Bookings-tab fixes including the platform-calculated advance.

**Previous capsule:** v1–v47 (see `docs/CHANGELOG.md` / `docs/CHANGELOG_v1-v7.md`)

---

## Project Identity (unchanged)

- **App:** GMS – dual-role service marketplace (Flutter Web + Android + FastAPI + PostgreSQL)
- **Dev:** M K Rathish (vmkrathish on GitHub), on macOS
- **Backend:** Render free tier — `https://gms-343g.onrender.com`
- **Database:** Supabase PostgreSQL
- **Local dev DB password:** `vmk1819` (user `postgres`, db `gms_db`, `localhost:5432`)
- **Firebase project:** `gms---get-my-service`
- **Seed login:** any account, password `1819`

---

## 1. Firebase Cloud Messaging — Android + Web Push

### What's built
- `core/services/fcm_service.dart` — permission request, multi-device token registration (via existing `user_push_tokens` table, not a single-token column), token refresh listening, foreground/background/terminated message handling, deep-link tap navigation.
- `core/services/foreground_notifier.dart` (+ `_mobile.dart` / `_web.dart`) — **conditional-import pattern**, because `flutter_local_notifications` doesn't officially support Web and `dart:html` doesn't exist on Android/iOS. This is the fix for "no popup while app is open" — FCM never auto-displays a system notification while the app is foregrounded, on Android or in a browser; that's expected FCM behavior, not a bug, and was the actual root cause of both the Android and Web "no popup" reports.
- Android: `google-services.json` placed, Google Services Gradle plugin wired at project + app level, `isCoreLibraryDesugaringEnabled = true` + `coreLibraryDesugaring` dependency added (required by `flutter_local_notifications`, was causing a release build failure), default notification channel (`gms_default_channel`) registered in `AndroidManifest.xml` so background/terminated pushes use the same high-importance channel as foreground ones.
- Web: `web/firebase-messaging-sw.js` service worker, real Firebase Web config wired in (`apiKey`, `authDomain`, `appId` — obtained from you), VAPID key wired in.
- Backend: real Firebase service account credential wired in locally at `backend/secrets/firebase-service-account.json` (gitignored, **never included in any delivered zip** — verified via a per-file scan of every zip before delivery). Render needs this uploaded as a **Secret File** at path `firebase-service-account.json`, plus an **Environment Variable** `GOOGLE_APPLICATION_CREDENTIALS` = `/etc/secrets/firebase-service-account.json` (Render doesn't allow slashes in Secret File names, so the file must be flat and the env var points to where Render actually mounts it).
- `notify.py` — detailed diagnostic logging at every stage (event created → recipient → tokens found → FCM attempted → success/failure per token), notification history row always created first regardless of push outcome.
- Fixed a real logging-order bug in `main.py`: `logging.basicConfig()` was running *after* the router imports, which transitively trigger `notify.py`'s Firebase init at module-import time — meaning the very log line needed to diagnose Firebase issues was being silently dropped. Fixed by moving `basicConfig()` before the router imports.

### Verified live
- Real Firebase Admin SDK initialization confirmed (`"notify: Firebase Admin SDK initialized"`).
- Full notify() diagnostic chain traced end-to-end with a real token, down to the exact real error (`Host not in allowlist: oauth2.googleapis.com`) — confirmed to be **this sandbox's own network restriction**, not a problem with the credential or the code. Render has full internet access and won't hit this.
- Notification history row confirmed created even when push delivery fails, per spec.

### Known gap
Real device/browser push delivery has never been verified from a real deployment — only the code path up to the network boundary. Needs verification once deployed to Render with the real credential.

---

## 2. Real-time chat — timezone fix + delivery ticks

### Timezone bug (root cause found and fixed everywhere)
Postgres/Supabase return UTC (`SHOW timezone` confirmed `Etc/UTC`), but the old `parseServerTime()` treated naive timestamp strings as already-local — meaning every timestamp was off by exactly the UTC↔IST gap (5.5 hours). This single bug explained **two** separate-looking reports at once: wrong message clock times, and "last seen 5 hours ago" for someone active seconds ago (both are the same miscalculation, showing up two different ways). Fixed in `time_format.dart` and reused everywhere — also fixed 3 other places that had bypassed the shared helper with their own raw `DateTime.parse` (payments screen, bookings screen, notification model).

### Three-state message ticks (single / grey double / blue double)
Added `messages.delivered_at` column. Previously only two states existed (sent/read), jumping straight from single tick to blue — no "delivered" concept existed anywhere.
- **Delivered** = the recipient's client is confirmed online (their app polls `GET /chats` every ~20s the whole time it's running — this endpoint now marks any of their undelivered messages as delivered, regardless of whether they've opened that specific thread).
- **Read** = they've actually opened the thread.
- Proven live: message sent → recipient's client polls conversations (not the specific thread) → grey double tick appears, `is_read` stays false → recipient opens the thread → blue tick, `delivered_at` timestamp **unchanged** (matches real WhatsApp behavior — delivered time doesn't get re-stamped).

---

## 3. Platform-controlled pricing & real review system

This was a large, phased build. Full spec was scaled back on one piece — see below.

### New tables
`platform_config` (admin-tunable rules, not hardcoded), `market_price_reference` (admin-maintained market data — see note below), `pricing_state` (one row per service: base price, max allowed, eligibility), `price_history` (full audit trail).

### Config values (all in `platform_config`, changeable without a code change)
| key | value |
|---|---|
| `max_price_increase_pct` | 20 |
| `max_price_decrease_pct` | 20 |
| `rating_qualification_threshold` | 4.5 |
| `quality_period_months` | 3 |
| `market_general_weight` | 0.5 |
| `advance_percent` | **25** (corrected from an initial 20% mention) |

### Scaled-back scope, by design
Live web-scraping for "general internet market pricing" was **not built** — blocked by this sandbox's network restrictions, and a real compliant scraper is its own serious undertaking (per-source legal review, robots.txt, rate limiting, maintenance). Built an **admin-maintained market price reference table** instead, feeding the same downstream calculation (median/weighted blend of general + locality data) — you were asked and confirmed "carry on" with this approach.

### What's enforced now (proven live, not just written)
- **Providers can no longer set their own price**, at creation or on edit. `create_service` calculates the base price from market reference data (general + locality, weighted blend); `update_service` validates any price edit against the platform-calculated range, backend-enforced (never trust frontend alone).
- **Review submission didn't exist as a working endpoint before this** — built from scratch with full verification: booking must be `completed`, `advance_paid = true`, one review per booking (DB-level unique constraint already existed), customer-only.
- **3-month service-specific quality window** — via the existing `reviews → bookings → service_id` chain (no redundant column needed), so a provider's Bike Repair and Plumbing ratings are genuinely independent, not blended into one overall score.
- **A price reduction becomes the new permanent base** — proven live: base cut from ₹425 → ₹340, then a later 20% increase calculated correctly from ₹340 (→ ₹408), never reverting to the original ₹425.
- Full live end-to-end proof chain: submit bogus price at creation → ignored, real ₹425 calculated → try ₹700 before earning it → rejected with exact spec-format message → try reviewing a cancelled/unpaid booking → rejected → real paid+completed review accepted → price range genuinely expands → previously-rejected price now accepted.

### Search fairness fix (found during this work, unrelated root cause than assumed)
"New providers not appearing in search" was **not** a caching bug — `ORDER BY average_rating DESC` was sorting every zero-review provider to the literal bottom of every paginated result, forever. Fixed in 3 places (main search, recommended-fallback, and the Python-side personalized scoring) by giving zero-review providers a **neutral placeholder score** (the platform-wide average) for ranking only — the customer-facing display still honestly shows 0 / "no reviews yet". Proven live: a fresh test provider went from "buried past position 100+" to position 2 of 12 in a real category search.

---

## 4. Four concrete bug fixes (user-reported, screenshot-driven)

1. **Fake "Rathish" default profile** — `userProfile`'s hardcoded starting value was an actual real person's real name, email, and phone number, shown briefly on *every* fresh session before real data loaded. Not a cosmetic bug — someone else's real PII on someone else's screen. Fixed to a neutral "Loading…" placeholder.
2. **"Service Details" dialog overflow at 6+ services** — this dialog (distinct from the "Edit Service" dialog fixed earlier) had *zero* height constraint and *zero* scroll wrapper at all. Fixed with adaptive height + `SingleChildScrollView`.
3. **Review count inflation** — `review_count` is a provider-level aggregate (same number repeated on every one of that provider's services, confirmed via `GROUP BY provider_id` in the SQL), but the public profile screen was *summing* it once per service. A provider with 1 real review and 2 services showed "2 reviews." Fixed to read the value once.
4. **Customer → Provider role promotion, and a related silent-failure bug**:
   - Built: a brand-new signup starts as `role='customer'` and now **genuinely flips to `provider`** the instant they successfully create their first service — proven live end-to-end (real signup → confirmed `customer` → create service → confirmed `provider` in the database, with the promotion logged).
   - Found as a side effect of the pricing work above: editing an existing service's price would call the backend but **never check if it actually succeeded** — so when the new price validation correctly rejected an out-of-range value, the dialog closed as if it worked, with the failure silently discarded. Fixed to surface the real error message.
   - Follow-up bug found from this fix actually working: a brand-new signup with no city set yet would hit a confusing generic backend error ("title, category_id and city are required") when trying to add a service, since `city` comes from the shared profile, not the service dialog. Fixed with a pre-check and a clear, actionable message ("Please set your city in Edit Profile before adding a service").

---

## 5. Full database regeneration — real dataset

Replaced the entire ~100-user synthetic seed with data derived from your real CSV (`gms_users_services_100.csv`), built via a custom Python generator (not hand-written SQL).

| | Before | Now |
|---|---|---|
| Users | 100 fictional | **105 real** |
| Services | ~153 | 291 |
| Bookings | 153 | 220 (realistic status spread) |
| Reviews | 45 | **113** |
| Messages | ~15 | 146, across 41 real threads |

- 66 distinct real-world skills mapped to the 41 real service categories (sports/hobby skills like "Cricketer" fell back to General Services rather than being force-fit or silently dropped).
- Specifically preserved with real activity: **Haresh, Ramachandran, Pushpitha, Sri Lakshmi, Sri Muthu Lakshmi** (all pre-existing seed people, kept and given services/bookings/reviews). **Arjun** and **Praveen S** are the real, honest CSV matches for "Arjun Komban" / "J V Praveen Kumar" — the fuller names aren't in your actual data, so they weren't fabricated.
- **Rathish ↔ Sasmitha** given dedicated, realistic booking + review + chat history — proven live by logging in with Rathish's *real* CSV phone number and pulling his real chat thread and real review straight through the live API, not assumed from the generator script.
- Old `notifications` seed data was dropped entirely rather than left pointing at booking IDs that no longer exist — notifications build up naturally from real app usage instead.
- Applied with **zero errors**, `bookings_missing_timeline: 0` (every booking has a complete event trail).

---

## 6. README.md refactor

- `## About` rewritten as professional prose instead of a bare bullet list.
- Project structure section updated to precisely match the real repo layout (`LICENSE`, `.gitignore`, `assets/logo.png` explicitly noted, `docs/` split into `CHANGELOG.md` + `CHANGELOG_v1-v7.md`).

---

## 7. Bookings tab fixes

1. **Reschedule reason — real asymmetry found and fixed.** The provider's `reschedule` action already required a reason on the backend; the customer's `counter_proposal` did not (frontend literally labeled it "optional"). Fixed both directions on the backend, **and** fixed the dialog itself: it previously closed immediately and showed a separate error afterward; now it stays open with an inline error until a reason is actually entered. Proven live: both paths correctly reject an empty reason with the right message.
2. **`BookingBadgeService` + auto-refresh** — new service mirrors the proven `ChatBadgeService` pattern exactly. Badge counts bookings that need *this* user's response right now: as customer, a proposed reschedule or an advance due; as provider, a new request or a customer's reschedule proposal. Wired into the bottom nav, app lifecycle (start/stop/logout-reset), and immediate-refresh-on-tab-open. Added 15-second silent background polling to the Bookings screen itself so a status change made by the *other* party shows up without leaving and returning to the tab.
3. **25% platform-calculated advance, replacing manual entry entirely** — the actual fix requested (initially described as 20%, corrected to 25% mid-conversation; stored in `platform_config` as `advance_percent`, not hardcoded). `create_service`'s pattern reused: the client's submitted amount is now completely ignored. Proven live with a deliberate injection test — tried to submit a bogus `advance_amount: 9999` while accepting a real ₹600 booking, backend correctly returned `₹150.00` (exactly 25%) regardless. Frontend "Accept" dialog changed from a free-text amount field to a calculated, read-only preview.

### Not yet started
The escrow/custody/wallet/dispute system described (advance held in platform custody until service completion, no-show complaint filing, provider time-extension requests, refund-to-wallet on a valid complaint, provider reputation penalty) is a genuinely large, separate system on its own — no code written yet. Needs a scoping conversation before starting, given its size and that it touches money-adjacent workflow.

---

## Critical Lessons Added This Session

1. **Render Secret Files don't allow slashes in the filename** — must be flat (`firebase-service-account.json`), then reference the actual mount path (`/etc/secrets/<filename>`) via a separate plain Environment Variable, since the app's code reads that env var to override its hardcoded default path.
2. **`flutter_local_notifications` doesn't officially support Web** — needed a genuine conditional-import split (`foreground_notifier_mobile.dart` / `_web.dart`), not one shared call.
3. **FCM never auto-shows a popup while the app is foregrounded** — this is expected behavior on both Android and Web, not a delivery failure; needed an explicit local-notification call in the `onMessage` handler.
4. **A provider-level SQL aggregate (`GROUP BY provider_id`) returns the same value on every row when joined against a per-service table** — safe to display once per service, but summing it across a provider's services silently multiplies the real count.
5. **Sorting zero-review items to the literal bottom via `COALESCE(rating, 0)` permanently buries new listings** — the fix is a neutral placeholder for ranking only, never changing what's actually displayed to the customer.
6. **A save operation whose result is never checked can fail completely silently** — always propagate the real backend error to the UI, especially once backend validation exists that didn't before.
7. **Logging configured after router imports silently drops the exact log line needed to diagnose the problem** — `logging.basicConfig()` must run before any import that transitively triggers module-level logging (this happened twice in this project now, in two different files).
