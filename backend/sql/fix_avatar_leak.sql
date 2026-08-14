-- ═══════════════════════════════════════════════════
--  GMS — Fix avatar leak + add safeguard
--
--  What happened: a manual UPDATE without a WHERE clause set
--  avatar_url to the same value for every row in `users`, which
--  is why Shree Sasmitha's photo appeared on Kisanth's, Rathish's,
--  and everyone else's avatar. The app's queries were never the
--  problem — they already returned each user's own avatar_url
--  correctly (verified live against the API).
--
--  Run:   mysql -u root -p gms_db < fix_avatar_leak.sql
-- ═══════════════════════════════════════════════════
USE gms_db;

-- STEP 1 — Diagnose: this shows any avatar_url shared by more
-- than one user. If your leak is still present, you'll see one
-- row here with a count > 1 (the smoking gun for a missing WHERE).
SELECT avatar_url, COUNT(*) AS affected_users
FROM users
WHERE avatar_url IS NOT NULL
GROUP BY avatar_url
HAVING COUNT(*) > 1;

-- STEP 2 — Reset every user's avatar back to empty (safe default:
-- the app shows their name's first letter until they set a real one).
-- Comment this out if you'd rather fix rows one by one instead.
UPDATE users SET avatar_url = NULL;

-- STEP 3 — Set Shree Sasmitha's photo correctly (id = 2 only).
-- ⚠️ Always include the WHERE clause — this is the exact mistake
-- that caused the leak. Replace the URL with her real photo link.
UPDATE users
SET avatar_url = 'https://your-image-host.com/shree.jpg'
WHERE id = 2;

-- STEP 4 — Verify: only Shree's row should have a non-NULL avatar now.
SELECT id, name, avatar_url FROM users ORDER BY id;

-- STEP 5 — Add a DB-level safeguard going forward: rejects any
-- avatar_url that isn't a real http(s) link (typos, local file
-- paths, empty strings). This does NOT catch a missing-WHERE
-- mistake by itself (a valid URL applied to every row still
-- "looks" valid) — Step 1's diagnostic query is what catches that
-- pattern. Run this once; skip it if it already exists on your DB.
ALTER TABLE users
  ADD CONSTRAINT chk_avatar_url_format
  CHECK (avatar_url IS NULL OR avatar_url LIKE 'http%');

SELECT 'Avatar fix + safeguard applied ✅' AS status;
