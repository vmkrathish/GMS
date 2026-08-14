-- ═══════════════════════════════════════════════════
--  GMS — Quick Migration: add last_seen_at + read_at
--
--  Use this INSTEAD of the full gms_full_setup.sql if you
--  don't want to wipe your database — it only adds the two
--  columns that were missing (this is exactly the error you
--  hit: "Unknown column 'users.last_seen_at' in 'field list'").
--
--  Run:   mysql -u root -p gms_db < migration_add_presence.sql
-- ═══════════════════════════════════════════════════
USE gms_db;

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS last_seen_at DATETIME DEFAULT NULL AFTER fcm_token;

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS read_at DATETIME DEFAULT NULL AFTER is_read;

-- Optional: seed a bit of presence data so you can see the
-- "Online now" / "Last seen X ago" feature immediately.
UPDATE users SET last_seen_at = NOW() WHERE last_seen_at IS NULL;

SELECT 'Migration applied successfully ✅' AS status;
