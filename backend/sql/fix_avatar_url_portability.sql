-- ═══════════════════════════════════════════════════
--  GMS — Fix avatar URL portability
--
--  THE BUG: an earlier version of the upload endpoint stored the
--  FULL address (e.g. http://192.168.29.145:5001/static/avatars/x.png)
--  baked into avatar_url. That address is only valid for as long as
--  the backend keeps running at that exact host+port. The moment you
--  restart on a different WiFi network, a different port, or move to
--  a real server later, every OLD photo silently breaks — even though
--  the actual image file on disk never moved. New uploads "worked"
--  only because they baked in whatever address was current at that
--  moment.
--
--  THE FIX (already applied in the backend code): new uploads now
--  store only a RELATIVE path (e.g. /static/avatars/x.png). The app
--  builds the full URL at DISPLAY time using whatever server address
--  it's currently configured to talk to — so it keeps working no
--  matter how many times the server's address changes in the future.
--
--  THIS SCRIPT repairs any records already saved the old way. It only
--  touches rows that are OUR OWN uploaded files (contain
--  "/static/avatars/") — external avatar URLs (e.g. the pravatar.cc
--  demo photos in the seed data) are left completely untouched.
--
--  Safe to re-run — rows already in the correct relative-path form
--  are simply skipped (WHERE avatar_url NOT LIKE '/static/avatars/%').
--
--  Run:   mysql -u root -p gms_db < fix_avatar_url_portability.sql
-- ═══════════════════════════════════════════════════
USE gms_db;

-- STEP 0: update the CHECK constraint itself — the OLD constraint only
-- allowed values starting with 'http', which would reject every NEW
-- upload now that they're stored as relative paths. Safe to re-run;
-- ignore an error here if your DB doesn't have the old constraint at all.
ALTER TABLE users DROP CONSTRAINT IF EXISTS chk_avatar_url_format;
ALTER TABLE users ADD CONSTRAINT chk_avatar_url_format
  CHECK (avatar_url IS NULL
         OR avatar_url LIKE 'http%'
         OR avatar_url LIKE '/static/%');

-- Preview affected rows before changing anything
SELECT id, name, avatar_url AS old_value,
       CONCAT('/static/avatars/',
              SUBSTRING_INDEX(avatar_url, '/static/avatars/', -1)) AS new_value
FROM users
WHERE avatar_url LIKE '%/static/avatars/%'
  AND avatar_url NOT LIKE '/static/avatars/%';

-- Apply the fix
UPDATE users
SET avatar_url = CONCAT('/static/avatars/',
                         SUBSTRING_INDEX(avatar_url, '/static/avatars/', -1))
WHERE avatar_url LIKE '%/static/avatars/%'
  AND avatar_url NOT LIKE '/static/avatars/%';

SELECT ROW_COUNT() AS rows_fixed;

-- Verify: every one of OUR OWN avatars should now be a clean relative
-- path; external URLs (pravatar.cc etc.) are unaffected.
SELECT id, name, avatar_url FROM users WHERE avatar_url IS NOT NULL ORDER BY id;

SELECT 'Avatar URL portability fix applied ✅' AS status;
