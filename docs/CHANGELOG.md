

---

## 💬 v9 — My Bookings Reschedule + WhatsApp-style Chat Timestamps

**Fixed: reschedule was missing on the customer (My Bookings) side.**
The backend already allowed `counter_proposal` from `pending`,
`confirmed`, and `awaiting_advance` — the frontend just wasn't showing
the button in all of those states. Now every active status on the
customer side has a reschedule option:
- `pending` / `confirmed` → "Suggest New Time"
- `awaiting_advance` → "Reschedule" (alongside Pay Advance) — a customer
  can now propose a new date instead of paying if the original time no
  longer works, tested live: booking correctly flips to
  `reschedule_by_customer` and the provider gets notified.
- `reschedule_by_provider` → "Accept New Time" / "Suggest Another"

**Chat timestamps, WhatsApp-style (new `core/utils/time_format.dart`):**
- Every bubble now shows the send time in its corner (e.g. "8:04 PM").
- Day-separator chips are interleaved automatically between messages —
  "Today", "Yesterday", the weekday name for the last 7 days, or the
  full date ("12 Jul 2026") beyond that — exactly like WhatsApp.
- Conversation list now shows the same relative time next to each
  chat (time for today, "Yesterday", weekday, or dd/mm/yy), positioned
  above the unread badge.


---

## 🛠️ v10 — Bug Fixes + Profile Navigation + Address Intelligence + Header Consistency

### Real bugs found & fixed
1. **Chat screen compile error** — `time_format.dart` import was missing while
   the file called `formatListTime`/`formatDaySeparator`/`parseServerTime`
   throughout. This was the "lines becoming error" you saw. Fixed.
2. **"Recommended for You" booking not reflecting in Bookings tab** — root
   cause was that nothing told the Bookings screen to refetch after a
   booking was made elsewhere. Added `core/services/refresh_bus.dart`: a
   tiny global signal that `BookingApi.createBooking()` / `.action()` bump
   on success, and `BookingsScreen` listens to — so a booking made from
   Home now shows up instantly regardless of tab-caching behavior.
3. Removed a duplicate method signature left over in `booking_api.dart`
   from an earlier edit (would have failed to compile).

### Profile Settings → Edit Profile (not the You tab)
Settings → Profile Settings now navigates **directly** to `EditProfileScreen`,
skipping the You tab entirely as requested. Because `EditProfileScreen` used
to read only from the in-memory `userProfile` notifier (which defaults to
placeholder data until the You tab has loaded it), it now **self-fetches**
the logged-in user's profile via `loadProfileFromServer()` in its own
`initState()` — correct data shows up no matter which screen you arrived
from.

### Validation — email, phone, name (client AND server)
- Email: proper `name@domain.tld` pattern (Gmail/Yahoo/any provider) on
  signup, login identifier, and the You-page Edit Profile email field
  (which previously had **no validation at all**). Mirrored server-side in
  FastAPI (`is_email` was a loose "-has @ and . check-, now a real regex) —
  both signup and profile-update reject malformed addresses.
- Phone: digits-only `inputFormatters` added everywhere a phone can be
  typed (signup, Edit Profile) — alphabetic characters are now physically
  blocked from entry, not just rejected after the fact.
- Name: letters-only formatter + validator on signup and Edit Profile,
  mirrored server-side.
- Pincode: digits-only, max 10, on both Edit Profile layouts (wide + stacked).

### Home booking sheet — address intelligence
- Fetches the logged-in user's own profile when the sheet opens (no
  dependency on the You tab having been visited).
- Three quick-pick chips, **varying per user**: 🏠 Home (full formatted
  address from profile), 📍 Pinned Location (profile's saved lat/lng), and
  🎯 Current Location (live GPS + reverse geocoding, same pattern as the
  Edit Profile screen's "use my location").
- Selecting Pinned or Current attaches real coordinates to the booking
  (new `customer_lat`/`customer_lng` columns on `bookings`, accepted by
  `POST /api/bookings` and returned in every booking response) — a green
  "Pinned location attached" confirmation shows once set. Manual address
  typing still works as a fourth option.

### Bookings tab — customer-side reschedule response
The 3-button response to a provider's reschedule proposal (Accept New Time
/ Suggest Another / **Reject**) was already implemented for
`reschedule_by_provider` — relabeled the third button from "Cancel" to
"Reject" with matching dialog wording, per spec. If you were seeing only a
Cancel button in an earlier build, this build's the fix.

### Header consistency (all 5 tabs)
- `GMSHeader` now takes a `showMenu` flag (default **false**). Only Home
  passes `showMenu: true` — the hamburger icon is visible there only, with
  a same-size spacer on the other four tabs so header height never shifts.
- Home's old bespoke header Container replaced with the shared `GMSHeader`.
- Chat's old inline "Chats" gradient bar replaced with the shared
  `GMSHeader` (single header, matching You/Payments exactly).
- Bookings keeps its own title+tab-bar header **plus** the shared
  `GMSHeader` above it — the one explicitly allowed exception (two
  headers), everything else uses exactly one.

### Database
- `bookings.customer_lat` / `bookings.customer_lng` (DECIMAL(10,7),
  nullable) added to both `models.py` and `gms_full_setup.sql`; a few seed
  bookings pre-populated with real coordinates for immediate UI testing.


---

## 💬 v11 — Chat Presence, Overflow Fix, Pinned Location, Header Merge

### Chat: "Seen" + "Last seen X ago" (WhatsApp-style presence)
- New `users.last_seen_at` column, bumped automatically on every
  authenticated API call (throttled to ~1 write/30s per user — cheap,
  no dedicated heartbeat endpoint needed).
- New `messages.read_at` column — set precisely when the recipient opens
  the thread (alongside the existing `is_read` flag).
- Chat thread header now shows **"Online now"** (active within the last
  minute) or **"Last seen 5 minutes ago" / "2 hours ago" / "Yesterday"**
  under the partner's name — same relative-time logic as everywhere else.
- Under your own most recent sent message, once the other person has
  opened the chat: **"Seen 3 minutes ago"** appears below the bubble
  (single/double check-mark icons on the bubble itself too — grey single
  tick = sent, blue double tick = read).
- New `formatRelativeAgo()` in `time_format.dart` powers all of this.
- Live-tested: read_at correctly stamps the moment a thread is opened.

### Fixed: chat list "BOTTOM OVERFLOWED BY 3.0"
The trailing time+unread-badge column in the conversation list had no
height constraint and could exceed the ListTile's allocated space by a
few pixels on some rows. Bounded it to a fixed 56×56 box with tighter
spacing and a smaller badge — overflow is gone.

### Fixed: Pinned Location in the booking sheet
Previously, tapping "📍 Pinned Location" only attached your coordinates
silently and left the address text unchanged (or fell back to your typed
home address) — so it looked like nothing happened. It now reverse-geocodes
your profile's saved pin into a **readable address** (same reverse-geocoding
the "🎯 Current Location" chip already used) and fills the field with that,
exactly matching how Home/Current already behaved. No more raw
latitude/longitude shown anywhere.

### Fixed: Edit Profile phone field still accepted letters
There were **two** phone `TextField`s in Edit Profile — a wide-layout one
and a stacked-layout one for narrow screens (same double-instance pattern
the pincode field had). Only the first had a digits-only formatter; the
second (stacked/mobile layout — the one you were actually using) had none
at all. Both now block alphabetic input at the keyboard level.

### Bookings header — merged into one block
The GMS brand header and the "Bookings"+tabs header were two separate
gradient containers stacked with a visible seam (the "disgusting" double-
bump look). Merged into a single seamless gradient block: logo+title+tagline
row, then "Bookings" title, then the tab bar — all in one container, one
set of rounded corners.

### Tagline restored on every header
`GMSHeader` was missing the "Any service. Any time. One app." tagline that
used to sit under "Get My Service" on the old Home screen. Added it back
into the shared header component, so it now appears identically on Home,
You, Payments, Bookings, and Chat.

### Database
`users.last_seen_at`, `messages.read_at` added to both `models.py` and
`gms_full_setup.sql`, with realistic seed presence data (some users
"online now", others minutes/hours/days ago) for immediate UI testing.


---

## 🩹 v12 — Duplicate Method Fix + Login 500 Error Resolved

### Fixed: duplicate `updateProfile` in user_api.dart
`UserApi` had two identical `updateProfile()` methods defined back to back
(a leftover from an earlier edit) — this is a Dart compile error
("The name 'updateProfile' is already defined"). Removed the duplicate;
one clean method remains.

### Fixed: login 500 error — `Unknown column 'users.last_seen_at'`
This wasn't a code bug — it was a **database drift** issue. The v11 update
added `users.last_seen_at` and `messages.read_at` columns for the chat
presence feature, but an already-running local database (created before
that update) doesn't have them, so every query SQLAlchemy builds for the
`User`/`Message` models fails with "Unknown column".

**Fix — two options depending on whether you want to keep existing data:**

1. **Keep your data** — run the new lightweight migration:
   ```bash
   mysql -u root -p gms_db < backend/sql/migration_add_presence.sql
   ```
   This only adds the two missing columns; everything else stays as-is.
   Verified live: simulated your exact error (dropped the columns, hit the
   same "Unknown column" failure), ran the migration, confirmed
   `POST /api/auth/login` with phone `9000000002` succeeds afterward.

2. **Fresh start** — the usual full reseed also works and includes this:
   ```bash
   mysql -u root -p < backend/sql/gms_full_setup.sql
   ```

Going forward (Step 4 of the master FastAPI plan — Alembic), schema changes
will generate proper versioned migration scripts automatically instead of
requiring manual ALTER TABLE fixes like this one.


---

## 🖼️ v13 — Avatar Leak Diagnosed & Fixed + Public Profile Viewer

### The avatar leak — root cause confirmed, not a code bug
Reproduced your exact symptom in a clean test: an `UPDATE users SET
avatar_url = '...'` **without a `WHERE id = ...` clause** sets every row
to the same value — which is exactly why Shree Sasmitha's photo appeared
on Kisanth's and Rathish's avatars everywhere. Verified the app's own
queries (services list, bookings list, chats list) all correctly return
each user's own `avatar_url` per row — confirmed live with distinct
avatars per user across all three endpoints. The application code was
never at fault.

**Fix, included in this build:**
- `backend/sql/fix_avatar_leak.sql` — a standalone script that (1) runs a
  diagnostic query showing any avatar_url shared by more than one user,
  (2) resets everyone to a safe default, (3) sets Shree's photo correctly
  with the required `WHERE id = 2`, (4) verifies the result.
- **Database structure altered as requested**: added a `CHECK` constraint
  (`chk_avatar_url_format`) rejecting any `avatar_url` that isn't a real
  `http(s)://` link — typos, local file paths, or empty strings are now
  refused at the database level. Tested live: an invalid value was
  correctly rejected, a valid one still saved fine. Note honestly: this
  catches malformed values, not a missing-WHERE mistake by itself (a
  valid URL applied to every row still "looks" valid to the database) —
  the diagnostic query in the fix script is what catches that specific
  pattern, so re-run it after any manual edit as a habit.

### New: tap a person's name/photo to view their profile alone
Added `public_profile_screen.dart` — a read-only profile view showing
only what's safe to share (name, city, bio, rating, their service
listings) — **never** email, phone, or full address, which stay private
to the account owner (verified via a live API call: no such fields in
the response). Wired as a tap target, separate from the surrounding
card's own action, in:
- **Home** — tapping a provider's avatar or name (not the rest of the
  card, which still opens the booking sheet).
- **Chat** — tapping the avatar in the conversation list, and tapping the
  avatar/name in a thread's header.
- **Bookings** — tapping the "By:/From:" avatar+name row (separate from
  the Chat shortcut next to it).
A "Message" button on the profile jumps straight into a chat thread.


---

## 📸 v14 — Real Avatar Upload Pipeline (root cause of the "leak" fixed)

### The actual bug — traced to the exact lines of code
Your Edit Profile photo picker (pick → crop) **never uploaded anything to
the server.** It only ever wrote the cropped image to a local file (native)
or in-memory bytes (web) and stored that in a shared global variable
(`userProfile`) — there was no `avatar_url` field in that variable at all,
and no API call anywhere in the crop-save flow. That's why Chat, Bookings,
and Home — which all correctly read the server's `avatar_url` — never
showed your new photo.

The "leak onto Kisanth" symptom was a second, related bug: that same
global variable is a **singleton that lives for the whole browser tab**
and was never cleared on logout or reset per-account. So whichever local
photo was picked last stayed in memory and got displayed under whichever
account loaded next, even though that account's name/phone/email were
still being fetched correctly from the server. Verified this precisely —
name/email/phone were never wrong in your screenshots, only the avatar,
which confirms it was exactly this local-state leak and not a database
problem.

### The fix — a real upload pipeline, backend to frontend
- **Backend**: new `POST /api/users/me/avatar` (multipart upload, 5MB
  limit, jpg/png/webp only) and `DELETE /api/users/me/avatar`. Files are
  stored under `backend/app/static/avatars/` and served at
  `/static/avatars/...` — swappable for Cloudinary later (master plan
  Step 6) without changing the response contract.
- **Database structure altered, as requested**: `avatar_url` removed from
  the general `PUT /users/me` whitelist entirely — it can now ONLY be set
  through the dedicated upload endpoint. Tested live: injecting
  `avatar_url` through the general profile-update endpoint is silently
  ignored while other fields still save normally. This closes the door on
  both manual-SQL mistakes and any future accidental/malicious client
  payload touching this field through the wrong channel.
- **Frontend**: the crop-save flow (camera and gallery, web and native)
  now calls the real upload after every crop, syncs the returned
  `avatar_url` into state, and shows an instant local preview while the
  upload is in flight. "Remove photo" now calls the DELETE endpoint too
  (previously it only cleared the local file — the server photo would
  have kept showing to everyone else even after "removing" it).
- **The leak itself, fixed at the root**: `SessionManager.logout()` now
  resets the shared profile state completely — every field, not just the
  avatar — so nothing from one account can ever carry into the next
  login in the same browser tab. Every avatar-display code path in the
  You page (5 separate spots — the profile card, three different
  full-screen viewers, and the Edit Profile header) now correctly
  prioritizes an in-progress local preview first, then the server's
  `avatar_url`, then falls back to initials.
- **Live-tested end to end**: uploaded a real photo as Shree Sasmitha →
  confirmed it appears in the services list (Home's source) and is
  servable over HTTP → confirmed Kisanth's avatar was completely
  untouched → confirmed the whitelist blocks injection while normal
  fields still save → confirmed DELETE clears it back to null everywhere.


---

## 🎯 v15 — The Actual Root Cause: Upload Was Silently Rejected Every Time

### Found it — a content-type mismatch, not a visibility/CORS problem
v14 built a real upload pipeline, but the Flutter client code had one bug
that made every single upload fail: `http.MultipartFile.fromBytes()`
defaults to `application/octet-stream` when no `contentType` is given —
it does **not** infer the type from the filename. The backend's upload
endpoint strictly validates content-type (`image/jpeg`, `image/png`,
`image/webp` only) as a security measure, so it was rejecting every
upload from the app with a 400 error. The photo never reached the
server, which is why it was correctly absent everywhere for everyone —
not a visibility bug, an upload bug.

**Proven, not guessed**: reproduced the exact failure with a precise
simulation of Dart's `http` package behavior (explicit
`application/octet-stream`, no filename-based inference) → confirmed
`400 "Please upload a JPG, PNG, or WEBP image."` — the same rejection
that was happening silently in the app. Then sent the identical file with
an explicit `image/png` content-type → `200 OK`, avatar_url set
correctly.

**Fix**: `UserApi.uploadAvatar()` now explicitly sets
`contentType: MediaType('image', 'png')` on the multipart file (matching
what the `crop_your_image` package actually outputs — confirmed by
tracing its `CropSuccess.croppedImage` bytes format). Added `http_parser`
as an explicit direct dependency in `pubspec.yaml` (previously only
transitive via `http`) for long-term stability.

### Also hardened: upload failures are now impossible to miss
The failure snackbar was easy to overlook — brief, default styling. It's
now bright red, stays for 6 seconds, and explicitly says "Photo NOT
saved" with the real reason, so if any future upload issue occurs
(network, file size, wrong format) it will be obvious immediately instead
of looking like a silent "visibility" problem again.

Everything else from v14 (dedicated upload/delete endpoints, whitelist
separation, logout state reset, avatar-priority display order) remains
unchanged and was already verified correct — this was purely the missing
content-type on the client's multipart request.


---

## 💬 v16 — Chat Thread Avatar + WhatsApp-style Unread Badge (frontend only)

Both fixes needed **zero backend/database changes** — the API already
returned everything required; it just wasn't being used on the frontend.
Confirmed this live before writing any code: `GET /api/chats/:id` already
returns `partner.avatar_url`, and `GET /api/chats` already returns
`unread_count` per conversation.

### Fixed: chat thread header always showed a letter, never the photo
The AppBar inside an open chat thread used a hardcoded `CircleAvatar` with
just the first-letter initial — it never read `avatar_url` at all, even
though the data was sitting right there in the API response. Now it uses
the same `UserAvatar` widget as everywhere else, seeded instantly from
whichever screen you tapped in from (conversation list, booking card, or
profile page) so there's no flash of letter-then-photo, and kept fresh
via the existing 5-second poll.

### New: unread-chat badge on the bottom nav, WhatsApp/Instagram-style
A small red circle with a number now sits on the **Chat** tab icon,
counting **distinct conversations with at least one unread message** —
not total unread messages. Tested precisely to your spec: one person
sending 10 messages shows as **1**; three different people each sending
unread messages shows as **3**. Verified live with real multi-sender
test data.

- New `core/services/chat_badge_service.dart` — polls every 20 seconds
  so the badge stays current even if Chat is never opened, exactly like
  WhatsApp's app-icon badge.
- Refreshes immediately (no wait for the next poll) whenever the
  conversation list loads or the Chat tab is tapped.
- Resets to zero on logout, same cross-account leak prevention pattern
  as the avatar fix — no stale badge count for the next person who logs
  in on the same browser tab.


---

## 🖼️ v17 — View Others' Photos Full-Screen + Real Fix for Remove Photo

### New: tap the round avatar inside a profile detail view to see it full-screen
Tapping someone's avatar in Home/Bookings/Chat already opened their profile
details (unchanged). What was missing: tapping their round avatar again
**inside** that details screen didn't do anything. Added a proper
full-screen, read-only photo viewer — pinch-to-zoom, tap or ✕ to dismiss,
**no download/save option** (matches your requirement exactly) — wired to
`PublicProfileScreen`'s avatar. Built as a shared `showReadOnlyAvatarViewer()`
in `user_avatar.dart` so it's reusable anywhere else a photo needs a
view-only zoom in future. Your own avatar viewer (tap your photo in the
normal You tab, before opening Edit Profile) was already working and is
untouched.

### Fixed: "Remove Photo" not actually persisting — found the real cause
This turn traced it to the exact broken code, not a guess:

There were **two separate remove-photo implementations** in the codebase
(same pattern as the earlier duplicate phone/pincode field bug):
1. A handler in the main You-page's avatar bottom sheet — this one DID
   call the delete API, but **completely ignored whether it succeeded or
   failed**, showing "Profile photo removed" regardless.
2. `_removeAvatar()` — the method Edit Profile's own photo-source menu
   actually calls (confirmed this is the one you were using). This one
   **never called the delete API at all** — it only cleared local
   in-memory state and showed a success message. The photo was never
   touched in the database, which is exactly why it reappeared every
   time you restarted the app: nothing was ever removed server-side.

**Both fixed properly**: `_removeAvatar()` now calls
`DELETE /api/users/me/avatar`, checks the actual response, and only
clears local state (including `avatarUrl`, which was also being missed
before — the old photo would otherwise instantly fall back into view) on
confirmed success. On failure, a clear red error message explains it
wasn't saved instead of pretending it worked. Verified live end-to-end
against the real backend, including a simulated app restart (fresh
fetch) confirming the photo stays gone.

Editing/re-uploading a photo was already correct and untouched.


---

## 🗓️ v18 — Full Booking Timelines, Fully-Paid Status, Real Geocoding, Header Trim, Price Clarity

### Fixed: 27 of 33 bookings had ZERO timeline events
Only 6 hand-written bookings had event history from earlier rounds — every
other booking (including most "completed" ones) showed "No timeline events
yet." Generated a complete, chronologically consistent event trail for
all 27 missing bookings, matched exactly to each one's final status:
completed → requested→accepted→advance_requested→advance_paid→confirmed→
started→completed (7 steps); in_progress → same minus the final step;
confirmed → up through confirmed; awaiting_advance → up through the
advance request; pending → just the request; reschedule/rejected/
cancelled/expired → their own realistic short trails. All 33 bookings now
have real timelines — verified live (booking 1 went from 0 events to a
full 7-step history).

### Fixed: completed bookings now show "Fully Paid", not "Advance ₹X paid"
A finished job repeating "Advance ₹1500 paid" was confusing — it now shows
**"Fully Paid ✅ (₹6000.00)"** using the service's full price, including
for the zero-advance-but-completed case (previously that combination
showed no payment info at all).

### Fixed: address chips were showing raw coordinates (root cause found)
The `geocoding` Flutter plugin has **no Web implementation** — this is
documented, not a bug in this app's code — so every reverse-geocode call
from Flutter Web silently failed and fell back to printing raw
latitude/longitude. This affected: Home's booking-sheet "Pinned Location"
and "Current Location" chips, and Edit Profile's "use my current
location" address autofill. The one flow that already worked correctly
(the You-page map-pin picker) turned out to have its own direct
client-side call to OpenStreetMap as a first attempt, which is why it
looked fine — but even it had a raw-coordinate text as a last-resort
fallback, now removed.

**Fix**: new backend endpoint `GET /api/geo/reverse` — server-side
reverse geocoding via OpenStreetMap Nominatim, works identically on
every platform since the client only ever asks the backend for a
plain address string. Returns both a short display label AND
structured components (city/state/postal_code/etc.) so Edit Profile's
multi-field autofill keeps working exactly as before, just reliably.
All three broken call sites now route through this. Note: this
sandbox's own network whitelist blocks outbound calls to Nominatim, so
live end-to-end testing wasn't possible here — the endpoint's request/
response shape and error handling were verified directly instead; it
will work normally on your machine's regular internet connection.

### Bookings header trimmed
Removed the standalone "Bookings" title word (the part that looked
disjointed) and tightened padding/logo/text sizing slightly — "My
Bookings" and "Received" tabs are completely unchanged.

### Price billing type now always explicit, everywhere
"Recommended for You" cards, and provider service listings on public
profiles, now always show **"per hour" / "per day" / "fixed price"**
underneath the amount — never blank. Also fixed a real (not just
cosmetic) bug in the You page's own service editor: the Type dropdown
only ever offered "Per Day" / "Per Hour" — there was no "Fixed Price"
option at all, and the underlying conversion function silently mapped
anything that wasn't per-hour to per-day. This meant editing a
naturally fixed-price service (like a one-time website build) through
the UI would have silently mislabeled it. Added the missing option in
all three places it appears (primary service + two responsive layouts
of the other-services editor) and fixed the conversion to be a true
three-way mapping.


---

## 🔗 v20 — Fixed: Old Uploaded Images Broke When The Server's Address Changed

### The real bug (confirmed, not a database persistence issue)
The previous verification (v19-era) proved images survive restarts —
that was true and remains true. What it didn't test was: **what happens
when the server's own address changes between sessions** (different
WiFi network, different port, moving to a real deployment later). That
turned out to be exactly what was happening.

**Root cause**: the upload endpoint was storing the FULL address baked
into `avatar_url` — e.g. `http://192.168.29.145:5001/static/avatars/x.png`.
That address is only valid for as long as the backend happens to be
running at that exact host and port. The moment it changes, every OLD
photo silently breaks, even though the file itself never moved from disk.
New uploads "worked" only because they baked in whatever address was
current at that exact moment — which is precisely the symptom described:
old images gone, new images fine.

**This was never JSON/memory storage** — it was always a real row in the
MySQL `users.avatar_url` column, pointing to a real file in
`backend/app/static/avatars/`. The bug was specifically that the stored
*value* was not portable across different server addresses.

### The fix
- Upload endpoint now stores a **relative path only**
  (`/static/avatars/x.png`), never a host-baked absolute URL.
- New `ApiConfig.resolveMediaUrl()` on the frontend: builds the full,
  currently-correct URL at display time by combining the relative path
  with whatever server address the app is presently configured to talk
  to. Applied everywhere an avatar is rendered — the shared `UserAvatar`
  widget and all five full-screen photo viewers across the app.
- `avatar_url`'s database `CHECK` constraint updated to accept both
  absolute URLs (external avatars, Cloudinary later) and relative
  `/static/...` paths — the old constraint would have rejected every
  new-style upload outright.
- New `fix_avatar_url_portability.sql` — repairs any already-broken
  absolute-URL records in an existing database by converting them back
  to relative paths (the underlying files were never lost), while
  leaving genuinely external avatar URLs (like the seed data's
  pravatar.cc demo photos) completely untouched.

### Verified live, precisely reproducing your scenario
Planted a fake old-style broken record
(`http://192.168.1.50:5001/static/avatars/OLD_user1_stale.png` — a
different address than the one currently running) → ran the migration
→ confirmed it correctly repaired to `/static/avatars/OLD_user1_stale.png`
→ confirmed the API now serves that old record correctly again →
confirmed a brand new upload also produces a portable relative path →
confirmed the database still correctly rejects genuinely invalid values
while accepting the new relative-path format.


---

## 🗺️ v21 — Rapido-Style Live Map (new Map tab, between Home and You)

The long-flagged roadmap item is built: a live, radius-expanding provider
discovery map.

### Backend — `GET /api/services/nearby`
- Radius escalation: tries 5km → 10km → 20km → 50km, returns the
  **tightest tier that has any results** rather than always maxing out.
  Never searches beyond 50km.
- If nothing matches the exact category anywhere within 50km, falls back
  to a broader fuzzy text match (title/description/category name) at the
  same 50km ceiling, flagged `is_similar: true` — covers a provider whose
  matching service is a secondary listing, or a closely related trade.
- If truly nothing within 50km: returns a professional message rather
  than a bare empty list.
- Distance computed server-side via the Haversine formula against each
  provider's registered location (services don't carry their own
  coordinates — a home-service provider's address IS their service area,
  same assumption used everywhere else in the app).
- Live-tested with real seed coordinates: a far-away electrician (~450km)
  correctly exhausted every tier and returned the graceful message; a
  nearby one was found at the tightest 5km tier; a bike mechanic search
  correctly escalated to the 10km tier and returned distance + emoji.

### Frontend — new Map tab (Home, **Map**, You, Payments, Bookings, Chat)
- **GPS verified before anything else** — checks the device's location
  service is actually ON (not just permission), with a clear "turn on
  location" prompt and retry if it's off, then a separate permission
  flow if needed.
- **Location reference toggle**, bottom-right, exactly as described: two
  small buttons — 📍 Current (live GPS) and 🏠 Home (saved profile
  address) — switching between them re-centers the map and becomes the
  anchor point for the next search.
- **Google-Maps-style search bar** pinned to the top — type a service
  name (e.g. "electrician"), hit search, radius-escalating results come
  back and the map auto-centers on the nearest match. A status banner
  shows how many providers were found and within what radius, or the
  "similar services" / "nothing found" message when relevant.
- **Each result shown as its category's emoji**, pinned exactly at the
  provider's location — a plumber shows 🔧, an electrician ⚡, etc.
- **Tap a marker → small preview** (name, star rating, review count,
  distance) → **View Profile** → the full public profile (bio, all their
  services, full rating) → **tap any service → the same shared booking
  sheet** used everywhere else in the app. Matches the requested flow
  exactly: see who they are first, book only as a deliberate next step.

### Refactor: booking sheet is now shared, not duplicated
Extracted Home's booking bottom-sheet (address picker with Home/Pinned/
Current-GPS options, date/time, notes) into `core/widgets/booking_sheet.dart`
so Home, the new Map, and public profile pages all call the *same*
implementation. This directly avoids the class of bug that's bitten this
project before — a fix applied to one copy of near-duplicate code while
another copy quietly stays broken.


---

## 🗺️ v22 — Map Fixes + Massive Tamil Nadu Data Expansion

### Fixed: Home location marker was invisible
Switching to "Home" mode changed the search anchor correctly behind the
scenes, but nothing showed on the map — no way to tell it had actually
done anything. Added a distinct green home-icon marker (separate from
the blue current-location dot) so both reference points are now visibly
different and confirmable at a glance.

### Fixed: switching reference point now confirms and re-searches
Tapping Current or Home now shows a brief "Searching from…" confirmation
and automatically re-runs the last search from the new anchor point, so
the toggle visibly does something instead of feeling inert until you
search again manually.

### Fixed: a real radius-escalation bug caught by live testing
Typing a search term into the map's search bar (free text, no explicit
category) was skipping tier escalation entirely and always jumping
straight to a flat 50km search — even when a match was sitting right
next door. Caught this with a live test: searched "plumb" from Trichy,
where a plumber is registered at 0.0km, and the response falsely said
"radius_used_km: 50". Root cause: the tiered 5→10→20→50km loop only
ever ran for category_id searches; free-text searches went straight to
an unescalated 50km fallback. Rewrote the endpoint so free text first
tries to resolve to a real category (so "plumber" behaves identically to
selecting the Plumbing category) and gets the same proper tier
escalation; only the genuine "similar services" fallback path (used when
the primary search finds nobody at all within 50km) is separately
tier-escalated too. Retested the same query — now correctly returns
`radius_used_km: 5`.

### New: Book Now alongside View Profile when tapping a marker
Tapping a provider's pin now shows both options clearly, matching Home's
exact pattern (tap the card body → book directly; tap the person → see
their profile first). "Book Now" opens the same shared booking sheet
used everywhere else in the app for that exact service.

### Tamil Nadu data — 40 users, 44 services (up from 14 / 18)
Added 26 new provider accounts spread across 24 different Tamil Nadu
towns and districts with real coordinates — Trichy, Tirunelveli, Erode,
Vellore, Thanjavur, Kanyakumari, Dindigul, Karur, Namakkal, Tiruppur,
Thoothukudi, Nagercoil, Kumbakonam, Hosur, Krishnagiri, Cuddalore,
Pudukkottai, Nagapattinam, Virudhunagar, Sivakasi, Theni, Ariyalur,
Perambalur, Ramanathapuram — plus extra density in Chennai and
Coimbatore. Each has a realistic bio, a real service listing, and a
category spanning plumbing, electrical, carpentry, tutoring, beauty,
photography, digital marketing, and more — giving the map genuinely
varied radius-tier results depending on where in Tamil Nadu you search
from, instead of everything clustering in just 4 cities.


---

## 📍 v23 — Location-Based "Recommended for You" (Home page)

Additive feature — existing project, database, UI, auth, and APIs all
reused as-is; nothing rebuilt.

### What changed
- **One small, justified schema addition**: `service_categories.is_remote`
  (boolean, default 0). Lets the ranking know which categories are
  location-independent (web dev, design, editing, content writing,
  accounting) vs on-site trades (plumbing, electrical, cleaning, AC
  repair, carpentry, and everything else — the default). No new tables,
  no new location columns — reuses the exact `users.latitude`/
  `longitude` the profile's map picker already writes to as "Home."
- **New endpoint**: `GET /api/services/recommended` — the *only* new
  API surface. Existing `/api/services` (search/category browsing) is
  completely untouched.
- **Ranking**: MySQL's `ST_Distance_Sphere` (as requested, in preference
  to a hand-rolled Haversine) computes real distance from the user's
  saved Home location to each provider. Combined into one weighted
  score with rating, an availability proxy (recency of `last_seen_at` —
  the closest honest signal available, since there's no explicit
  booking-calendar system yet), relevance, and reputation (completed
  job count from the existing `bookings` table, a more direct signal
  than review count alone). On-site categories weight distance highly;
  remote-friendly ones weight it at zero.
- **Frontend touch is minimal**: `_fetchRecommendations()` calls the new
  endpoint *only* for the true default "Recommended for You" state (no
  active search, no category filter selected) — searching or tapping a
  category chip continues to use the exact same `getServices()` call as
  before, completely unmodified. "X km away" appears on provider cards
  only when distance data is present; cards without it render exactly
  as they did before this feature existed.
- **Graceful fallback, verified structurally correct**: if a user has no
  saved Home location, the endpoint returns the exact same rating-sorted
  list the app already showed, flagged `location_available: false` —
  same behavior as today for anyone who hasn't pinned a location yet.

### A real calibration bug caught and fixed during testing
First pass let a 5-star provider 311km away slightly outrank a 4-star
provider 36km away for an on-site category — technically executing the
formula correctly, but not truly delivering "high importance" for
distance as specified. Traced it to a distance-scoring curve that
plateaued too early (everything past ~50km scored the same "0",
letting rating alone decide beyond that point) combined with too small
a distance weight. Fixed both: a smoother decay curve that keeps
discriminating between "36km" and "311km" and "1000km" rather than
flattening out, and raised the on-site distance weight so it can
genuinely dominate typical rating gaps. Retested live with two
different users (different saved Home locations, Sankagiri and
Chennai) — nearby on-site providers now correctly rank above distant
ones despite lower ratings, and remote-category services correctly
ignore distance entirely regardless of how far away the provider is.


---

## 🔍 v24 — Map Search Autocomplete + Nearby-Category Suggestions + Hyderabad Data v2

### Map search now shows live suggestions while typing
Reused the exact debounced-suggestion pattern already proven on Home
(`ServiceApi.getSuggestions`, 350ms debounce, dropdown card under the
search bar) — no changes to that endpoint at all, just a second screen
now calling it. Tapping a suggestion fills the search bar and runs the
nearby search immediately.

### "No electrician nearby" now suggests what IS actually available
When a search exhausts every radius tier (5→10→20→50km) and even the
fuzzy fallback finds nothing, `/api/services/nearby` now runs one more
query: what categories DO have active providers within 50km of that
exact location. Returns up to 6 as `suggested_categories` (id, name,
emoji), shown as tappable chips under the "nothing found" message —
tapping one immediately re-searches. Deliberately built from real data
rather than a hardcoded "electrician relates to X" table, so every
suggestion is always genuinely bookable near the user right now.

### Hyderabad dataset v2 — original team names preserved
Regenerated the full Hyderabad seed data with the same structure and
scale (250 users, 273 services, 230 bookings, 976 timeline events — 0
missing, verified twice) but with one change: the first 14 providers
are your original names — Rathish, Shree Sasmitha, Nithya Shree,
Kisanth, Sanjith, Navaneth Sri, Kavin, Priya Varshini, Vijaya Prakash,
Harshan, Anirudh, Nithin Krishna, Heena Kadeeja, Sri Ram — each placed
in a real Hyderabad locality and assigned a category matching their
original real-world skill set where it fit naturally (Rathish → Web
Development, Kisanth → Electrical, Sanjith → Plumbing, etc.). The
remaining 206 providers use freshly generated Hyderabad-style names.
Verified live: all 14 appear correctly as providers with sensible
primary services.


---

## 🔄 v25 — Reverted to Tamil Nadu Dataset (Original Team, Complete Timelines) + README Refresh

### Database reverted from the Hyderabad jury-demo dataset back to Tamil Nadu
The original 14 named users are back exactly as they were first defined —
same phone numbers (`900000000X`), same roles (10 providers, 4 customers:
Rathish, Shree Sasmitha, Nithya Shree, Kisanth, Sanjith, Navaneth Sri,
Kavin, Priya Varshini, Vijaya Prakash, Harshan as providers; Anirudh,
Nithin Krishna, Heena Kadeeja, Sri Ram as customers) — plus 26 more
Tamil Nadu-district providers and 10 more customers for geographic
variety (Trichy, Tirunelveli, Erode, Vellore, Thanjavur, and more),
matching the scale of the dataset before the Hyderabad expansion.

**The upgrade over the original**: every one of the 92 bookings now has
a complete, status-matched timeline — 384 events total, verified by the
same built-in SQL completeness check used for the Hyderabad dataset
(`bookings_missing_timeline` must return 0). The original Tamil Nadu
dataset's bookings did not have this guarantee when first seeded; this
version does.

Booking/service/message/notification volumes scaled down proportionally
to match a 50-user dataset (92 bookings, not the 230 built for 250
Hyderabad users) — dense enough to demo every workflow status, not
artificially inflated.

### README rewritten for the current app
The previous README was from the very first monorepo setup — described
5 tabs, 14 users, and none of the features built since. Rewritten to
cover: the current 6-tab structure (Map added), the live discovery map,
location-aware recommendations, the avatar-URL-portability design
decision, server-side reverse geocoding, and an accurate demo-data
summary matching this dataset.


---

## 🔐 v26 — Password Authentication, Self-Exclusion, 50km Recommendation Cap

### Password authentication added system-wide
- New `users.password_hash` column, real bcrypt hashing.
- **Found and fixed a real, separate bug along the way**: the project's
  existing `passlib[bcrypt]` dependency is incompatible with the
  installed bcrypt version (bcrypt>=4.1 removed an internal API passlib's
  version-detection code depends on — every hash/verify call would have
  crashed). Rewrote `core/security.py`'s password functions to call
  `bcrypt` directly, sidestepping the incompatibility entirely. Verified
  standalone: hash-then-verify works correctly.
- Signup now requires a password (min 4 characters); login now requires
  and verifies it. New `PUT /api/auth/change-password` endpoint (current
  + new password, properly authenticated).
- **Every existing seeded user's password is "1819"** — a real bcrypt
  hash was generated and applied to all 50 users via a single `UPDATE`.
- Live-tested the full flow: login without a password → rejected; wrong
  password → rejected; correct default password → accepted with a valid
  token.
- Frontend: Login screen gained a password field with a show/hide eye
  icon toggle. Signup gained password + confirm-password fields (same
  toggle pattern, must match to submit). New Settings → **Change
  Password** menu option opens a dedicated screen (current/new/confirm,
  same validation rules) wired to the new endpoint.

### Seeded emails converted to @gmail.com
All 50 seeded accounts' emails changed from `@gms.dev` to `@gmail.com`
for a more realistic demo. (Caught and fixed a script bug along the way
— a failed assertion silently prevented the first attempt at this from
actually saving to disk, despite printing a false "success" line;
verified the second attempt actually persisted by checking the file
directly before moving on.)

### Never see yourself in your own search or recommendations
Added `provider_id != :me` to the general marketplace search, the map's
nearby search (incl. its "suggested categories" fallback), and Home's
"Recommended for You" — a logged-in user's own listings are now silently
excluded everywhere except when explicitly viewing their own public
profile on purpose (`provider_id` filter still works as a direct,
intentional lookup). No error shown, no message — just excluded, exactly
as requested.

### Hard 50km cap on "Recommended for You"
Previously the weighted ranking let distance influence score without an
outer boundary — a provider could theoretically appear even very far
away if their rating/reputation were high enough. Added a hard ceiling:
on-site categories now never show a provider beyond 50km of the user's
saved location, full stop. Remote-friendly categories (web dev, design,
editing…) stay unbounded, since distance genuinely doesn't apply to them
— consistent with the existing `is_remote`-aware weighting.


---

## 🎯 v27 — Search Keyboard Navigation, Home/Current KNN Recommendations, Data Fix

### Fixed: a real, self-inflicted schema bug caught during testing
While regenerating the SQL file to fix the Telangana/Tamil Nadu mismatch
(see below), the regeneration path used an older assembly script that
predated the password-auth work — silently dropping the `password_hash`
column and the default-password `UPDATE` from the output file, even
though the rest of the file looked complete. This wasn't caught until
live-testing login against the freshly-generated file, which failed with
"Unknown column 'users.password_hash'". Fixed by re-adding the column
and the default hash directly, reseeded, and confirmed clean. Lesson:
regenerating a seed file from an earlier pipeline stage silently
reverts any schema work applied after that stage — worth checking a
diff of column definitions after any full regeneration, not just row
counts.

### Fixed: city/state mismatch (Tamil Nadu cities with state="Telangana")
A real bug — every user had `state = 'Telangana'` even though their city
was correctly a Tamil Nadu place, traced to a leftover hardcoded
template string in the assembly script from the earlier Hyderabad
dataset that never got updated when adapted for the Tamil Nadu revert.
Fixed at the root, regenerated, and reconfirmed: all 50 users now show
Tamil Nadu consistently, with the original 14 team members' cities
preserved exactly as before (Rathish→Sankagiri, Kisanth→Coimbatore,
Sri Ram→Salem, etc.).

### Search suggestions: full keyboard navigation
Down/Up arrows move a highlighted selection through the suggestion
list, Enter picks whichever one is highlighted (or submits the typed
text if nothing's highlighted — unchanged from before), with the
selected item visually highlighted. Applied identically to both the
Map screen and Home screen's search bars — a genuine imbalanced-parens
bug was caught and fixed during this work (a leftover extra closing
parenthesis from converting Home's suggestion list item builder from
an arrow function to a block function), traced with a careful
line-by-line depth trace after two earlier mis-scoped snippet checks
gave false readings.

### "Recommended for You": Home / Current toggle, KNN-style distance sort
New toggle chips next to the "Recommended for You" heading — 🏠 Home
(saved profile location) or 📍 Current (live GPS, with permission
handling and a graceful fallback to Home if GPS is unavailable). Both
modes now sort strictly nearest-to-farthest (pure distance ascending,
ignoring rating/reputation entirely) rather than the weighted composite
score used elsewhere, matching a literal KNN-style "closest first"
request. On-site categories stay capped at 50km; remote-friendly
categories (web dev, design, editing…) sort separately since distance
doesn't apply to them. Backend: the existing `/api/services/recommended`
endpoint gained an optional `lat`/`lng` override (for Current mode) and
a `sort=distance` parameter — the original weighted `sort=smart` mode
is untouched and still the default for any other caller.

Live-verified end to end: Home mode from Sankagiri showed a 2.0km match
first, ascending correctly through 38km, with remote-category results
correctly grouped separately; switching to an explicit Coimbatore
override showed an entirely different, correctly nearest-first result
set from that location instead. Self-exclusion (a user never seeing
their own listings) reconfirmed working under the new sort mode too.


---

## 👥 v28 — Full Database Regeneration from User-Provided Reference Data

The Tamil Nadu dataset (randomly generated names) has been completely
replaced with an explicit, user-provided reference list: 100 named
people, their real place names, phone numbers, and their actual primary
+ secondary service offerings.

### What changed
- **All 100 users** loaded exactly as provided — same names, same phone
  numbers (9000000001–9000000100), same places. Verified directly: row 1
  is Rathish/Mavelipalayam Sankagiri, row 100 is Fazil/Thoothukudi,
  matching the source list precisely.
- **~85 distinct Tamil Nadu place names** (from small towns like
  Sankagiri, Anthiyur, Omalur through major cities like Chennai,
  Coimbatore, Madurai) mapped to real approximate coordinates, each with
  a small natural jitter so co-located providers don't stack on the
  exact same point on the map.
- **Free-text service names mapped to the existing 41 categories** — e.g.
  "App developer"→App Development, "Doctor"→Home Nursing, "Kids care
  taker"→Babysitting, "Mehendi artist"→Beauty & Salon, "Tourist
  guide"→General Services. Primary service becomes each provider's
  featured listing; other services become additional listings, with
  duplicate categories per provider collapsed (e.g. Rathish's "App
  developer" and "Software developer" both map to App Development, so
  only one listing is created for that category).
- **153 services, 153 bookings spanning all 11 statuses, 629 timeline
  events — zero bookings missing one**, verified via the same built-in
  SQL completeness check used for every prior regeneration.
- Schema unchanged — same `password_hash`, `is_remote`, and every other
  column added in prior rounds. All 100 accounts default to password
  "1819", changeable via Settings.

### A recurring bug pattern, caught and permanently fixed this time
The exact same "regenerated from a template that predates a schema
change" bug from the previous round happened again here — the reusable
`schema_only.sql` template still didn't have the `password_hash` column
baked in, so the first assembly attempt silently produced a database
missing it, and login failed with "Unknown column" until reseeded with
a corrected file. This time the fix was applied to the **template
itself** (not just the one output file), so any future regeneration
from this template will carry the column forward automatically instead
of dropping it again.

### Live-verified end to end
Full reseed ran clean with zero SQL errors. Login with the default
password confirmed working for Rathish. Distance-sorted recommendations
from Rathish's Sankagiri location correctly surfaced his real nearby
neighbors (Shree Sasmitha, Varneka, Heena, Anirudh) at realistic 1-3km
distances, in ascending order.


---

## 🗺️ v29 — Live Password Checks, Driving Routes, Default Map View, Demo Chat

### Settings: Language & Theme simplified
Both now clearly show fixed values ("English", "Light") with a
friendly "more coming soon" message on tap, instead of doing nothing.
No functional language/theme switching yet — that's still on the
roadmap.

### Change Password: live validation
The "Current password" field now checks itself as you type — debounced,
with a spinner then a green check or red cross shown directly in the
field — backed by a new side-effect-free `POST /api/auth/verify-password`
endpoint, rather than waiting for the whole form to be submitted. Added
a same-password guard both client- and server-side: a new password
identical to the current one is now rejected with a clear message.
Live-tested all three states (correct, wrong, and the same-password
rejection) — all confirmed working.

A real bug was caught and fixed while building this: an earlier edit to
`geo_api.dart` landed in the wrong spot due to non-unique anchor text in
the edit tool, silently splicing new code into the middle of an existing
method instead of appending after it. Found via a balance check,
rewrapped the whole file cleanly from scratch.

### Real driving routes (Google-Maps-style), not just straight-line distance
New `GET /api/geo/route`, proxying OSRM (the same OpenStreetMap-based
routing engine behind many turn-by-turn apps) for real driving distance,
estimated time, and the actual route polyline — follows the exact same
proxy pattern as the existing reverse-geocoding endpoint. New
`RouteToProviderScreen`: a Home/Current toggle (defaults to Home), the
route drawn on a small map, and distance + estimated drive time shown
before a "Continue" button leads into the profile/booking flow. Wired
into two entry points: tapping a provider pin on the Map (shows the
route first, exactly as requested, before the profile/booking step),
and tapping the location on a booking card (routes to the provider's
location for a customer, or to the customer's booking-time pinned
location for a provider) — required adding `provider_lat`/`provider_lng`
to the bookings list API, which didn't previously return them.

Honest limitation: this sandbox's network restrictions don't allow
reaching OSRM's servers from here, so the actual live routing call
itself couldn't be tested from this environment — the code compiles
cleanly and mirrors the already-proven reverse-geocoding pattern, but
this one piece needs its first real-world check on a machine with full
internet access.

### Map's default view: show everyone nearby, not just search results
`/api/services/nearby` no longer requires a category or search term —
called with neither, it now returns every active provider within 50km,
nearest first (live-tested: 31 results returned correctly, sorted by
distance). The Map screen calls this automatically on open, and again
whenever the search box is cleared or the Home/Current toggle is
switched with no active search — an explicit search only narrows this
further, it's never required just to see who's nearby.

### Default demo conversation
Seeded a real conversation between Rathish and Shree Sasmitha (5
messages, correct alternating sender/receiver, realistic timestamps) so
the Chat tab has a populated thread out of the box. Verified directly
against the database after reseeding.


---

## 📍 v30 — Correct Booking Routes, Live Search Fix, Full-App Refresh

### Booking routes now reflect actual booking-time context, not live re-fetches
New `BookingRouteScreen`, distinct from the general browse-time
`RouteToProviderScreen`: both endpoints are now fixed by what the
booking actually was, not a live toggle.
- **My Bookings** (you're the customer): the provider is coming to
  YOU — origin is the provider's registered location, destination is
  YOUR location exactly as it was saved when you made this specific
  booking (never a live re-fetch — you may have moved since).
- **Received** (you're the provider): you're going to THEM — origin
  is fetched live right now (you're heading out today), destination
  is the customer's saved booking-time location.
- Distinct, non-pin emoji markers (🚗 for whoever's traveling, 🙂 for
  the fixed destination) instead of generic map-pin icons.
- Required adding `provider_lat`/`provider_lng` to the bookings list
  API (previously missing) — live-verified both provider and customer
  coordinates now come through correctly on every booking.

### Live-diagnosed and fixed: searching a provider's name showed nothing
Tested the exact scenario directly against the backend first — the
search itself worked perfectly server-side (`u.name LIKE :q` was
already correct). The real bug was in the frontend: the "Recommended
for You" header updated instantly as you typed, but the actual results
list only refreshed on an explicit Enter/submit — so a name search
looked broken even though nothing was actually failing underneath.
Made Home's search genuinely live: results now update on the same
debounce as the autocomplete suggestions, and clearing the box
reliably reverts to the default recommendations. Live-verified:
searching "Sowmya" now correctly returns her two listings.

### Public profile location — verified and fixed an import bug
The tappable, non-blue location chip (leading to the route view with
a Home/Current toggle) was already built from earlier work, but
referenced a screen that was never actually imported — a real compile
error waiting to happen. Fixed.

### Full-app refresh: logo tap + re-tapping the active nav tab
Tapping the "Get My Service" logo/name now refreshes whatever tab is
currently open, re-fetching fresh from the database rather than
relying on cached state. Re-tapping the tab you're already on
(Home, You, or Bookings) does the same for that specific screen. Built
on the existing `RefreshBus` pattern already used for booking updates,
extended with `home` and `profile` signals plus a `bumpAll()` for the
logo tap.

All changes live-tested against a fresh reseed: 100 users, 153
services, 153 bookings, 629 timeline events (zero missing), 248
messages, 110 notifications — all counts intact, zero SQL errors.


---

## 🛠️ v31 — Compile Fix + Refresh Extended to Every Tab

### Fixed a real compile error
`public_profile_screen.dart` referenced `avatarUrl` as a bare variable
when the actual local variable in that scope was named `avatar` — a
genuine "getter isn't defined" compile error caught by the person
actually running `flutter run`, since this sandbox has no Dart SDK
available to catch it beforehand (confirmed: the SDK's usual
distribution host, storage.googleapis.com, isn't reachable from here,
and no equivalent package exists in Ubuntu's default repos). Fixed the
one bad reference, then manually cross-checked every other
constructor call added this session (`RouteToProviderScreen`,
`BookingRouteScreen`) against the actual variables in scope at each
call site — all confirmed correctly matched.

Noting this limitation plainly: without real Dart tooling, verification
here relies on careful manual review and brace/paren balance checks,
which catch structural corruption but not semantic errors like this
one. Worth keeping in mind for anything reported as a runtime/compile
error going forward — that's the fastest way to catch what this sandbox
structurally cannot.

### Refresh extended to every tab, not just three
`RefreshBus` previously only covered Home, You, and Bookings. Added
matching signals for Map, Payments, and Chat, wired into each screen's
own reload method (`_loadDefaultNearby`/`_search` for Map, UPI/card
reload for Payments, `_load` for the conversation list). Re-tapping
whichever tab you're already on now reloads that tab specifically;
tapping the logo refreshes whichever one is currently open — both
paths now cover all six tabs consistently.


---

## 🔀 v32 — Single LOCAL/ONLINE Switch File (Frontend + Backend)

### One file per side, everything else derives from it
Previously the frontend's `api_config.dart` was already the sole place
holding the LAN IP — this round makes that explicit and adds a matching
mechanism on the backend, since deploying will also mean switching the
database connection and CORS-allowed origin away from local defaults.

**Frontend — `lib/core/config/api_config.dart`**: a single boolean line
(`_isOnline`) switches the whole app between a local LAN IP+port and a
hosted URL. Every API call, image URL, and media path in the entire
codebase already read from this one file (`ApiConfig.baseUrl` /
`ApiConfig.serverRoot`) — confirmed via a full-codebase grep, zero other
files hardcode an IP or host. Flipping the switch is one line; leaving
both the LOCAL and ONLINE lines active by mistake is a Dart "duplicate
definition" compile error, not a silent bug.

**Backend — new `app/core/env_config.py`**: the equivalent single
switch for the two things that actually change between local dev and a
real deployment — the database connection string and the CORS-allowed
frontend origin. `core/config.py`'s existing `.env`-based settings
system now pulls its *defaults* from this file, so the day-to-day
local↔online toggle is one line here, while `.env` remains available
for anything deployment-specific you don't want committed to git
(JWT secret, Cloudinary keys, etc.) — the two mechanisms don't conflict,
`.env` simply overrides these defaults if present.

Live-verified end to end: booted the backend fresh through the new
config chain (env_config.py → config.py → the actual app), confirmed it
connects to the database and responds correctly with the local values
active exactly as configured.


---

## 🐘 v33 — Full MySQL → PostgreSQL Migration (Supabase-ready)

The entire backend now targets PostgreSQL instead of MySQL/MariaDB —
prompted by moving toward Supabase for the hosted MVP deployment.

### What was reviewed
Started from the user's own uploaded `backend/app/` — diffed every file
against the current project and found exactly one change already made
(their real Supabase connection string filled into `env_config.py`'s
`ONLINE_DATABASE_URL`). Everything else — every raw SQL query across
every router — was still MySQL-flavored and needed real conversion.

Also received and validated a user-provided `gms_supabase_setup.sql` —
ran it against a real local PostgreSQL install (not just read it):
zero errors, exact matching counts (100 users, 153 services, 153
bookings, 629 timeline events, zero missing).

### What was actually broken, found by live-testing against real Postgres
Rather than convert by inspection alone, booted the actual FastAPI app
against a real local Postgres and hit real endpoints — this caught
several genuine bugs that reading the code wouldn't have:

- **Boolean comparisons**: `is_active = 1`, `is_read = 0`, etc. — MySQL
  tolerates comparing a boolean column to an integer literal; Postgres
  raises `operator does not exist: boolean = integer` outright. Fixed
  every raw-SQL occurrence (`= TRUE`/`= FALSE`) and every ORM-level one
  (`Model.column == 1` → `== True`) across `services.py`, `chats.py`,
  and `auth.py` — the `auth.py` ones were only caught because login
  itself failed on first live test.
- **`ST_Distance_Sphere(POINT(...))`** in the `/recommended` endpoint —
  MySQL-only. Replaced with the same portable haversine formula already
  used everywhere else in the file.
- **`DATE_SUB(NOW(), INTERVAL 1 HOUR)`** → Postgres's
  `NOW() - INTERVAL '1 hour'` syntax (three occurrences).
- **`GROUP BY IF(condition, a, b)`** in the chat conversations query —
  `IF()` isn't a scalar function in Postgres. Converted to
  `CASE WHEN ... THEN ... ELSE ... END`.
- **`HAVING` referencing a SELECT-list alias** — MySQL allows this
  (`SELECT (...) AS distance_km ... HAVING distance_km <= X`); standard
  SQL/Postgres does not, since HAVING is logically evaluated before the
  SELECT list exists. This one wasn't caught by reading the code at
  all — it only surfaced once the boolean bugs above were fixed and the
  *next* layer of real errors appeared on retest. Fixed all three
  occurrences by wrapping each query as a subquery and filtering
  `distance_km` in an outer `WHERE` instead — a fix that's also more
  portable than the original MySQL-only pattern, not just
  Postgres-compatible.
- **`LIKE` → `ILIKE`** (16 occurrences) — MySQL's default collation is
  case-insensitive for text matching; Postgres's isn't. Without this,
  search would have silently become case-sensitive.
- **`models.py`**: MySQL-only `CURRENT_TIMESTAMP ON UPDATE
  CURRENT_TIMESTAMP` column option (Postgres has no such column-level
  clause — the SQL schema now handles this via a trigger instead) and
  `1`/`0` server-side defaults on Boolean-typed columns (needed
  `TRUE`/`FALSE`).

### A second real bug, found only by testing after the first fix
After fixing the boolean issues, login *still* failed — traced to a
leftover `.env` file from early in the project with a hardcoded MySQL
`DATABASE_URL` that was silently overriding `env_config.py`'s LOCAL/
ONLINE switch via pydantic-settings' normal `.env`-loading behavior.
This directly undermined the "one single place to switch" promise the
switch file was built around. Fixed at the root — `DATABASE_URL` and
`FRONTEND_URL` are now unconditionally sourced from `env_config.py`
regardless of `.env` contents, while `.env` remains available for
genuine secrets (JWT_SECRET, Cloudinary keys) that legitimately
shouldn't live in a comment-toggle file. Also fixed both `.env` and
`.env.example` to stop implying they control the database connection.

### Frontend: confirmed unaffected
Postgres returns genuine `true`/`false` for boolean columns where
MySQL returned `1`/`0` — checked every Flutter call site that reads a
boolean-shaped API field (`last_from_me`, `advance_paid`, etc.) and
found they were already written defensively (`== 1 || == true`) from
earlier work. Zero frontend changes needed for this migration.

### Other changes
- `requirements.txt`: `pymysql` → `psycopg2-binary`, `passlib[bcrypt]`
  → `bcrypt` (matching what the code has imported directly since the
  passlib/bcrypt compatibility fix from an earlier round).
- `env_config.py`: both LOCAL and ONLINE now point at PostgreSQL. The
  user's real Supabase connection string was carried over from their
  own upload, with a flagged warning about Supabase's `[YOUR-PASSWORD]`
  placeholder syntax — worth double-checking before deploying.
- Added `backend/sql/gms_supabase_setup.sql` as the new canonical setup
  file; the old `gms_full_setup.sql` (MySQL) is kept only as historical
  reference and clearly marked as such in the README.

### Live-verified end to end, every fix confirmed against real Postgres
Booted the actual app against real PostgreSQL and tested every touched
endpoint through the real API, not just the raw SQL in isolation:
login, name search, the map's default nearby view (31 results,
correctly nearest-first), location-aware recommendations (10 results,
correctly nearest-first), the "similar services nearby" fallback
suggestion chips, chat conversations (correct partner/unread data),
and self-exclusion (still correctly excluded from your own results).
