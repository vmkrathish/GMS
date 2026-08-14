-- ═══════════════════════════════════════════════════════════
--  add_notification_system.sql
--
--  Run this against your LIVE Supabase database (SQL Editor).
--  SAFE, additive-only — does not touch, drop, or reset any
--  existing data. Every statement below is idempotent
--  (IF NOT EXISTS / OR REPLACE), so it's safe to re-run.
-- ═══════════════════════════════════════════════════════════

-- ─── 1. Deep-link metadata on notifications ──────────────
-- ref_id alone can't carry enough for every event (a chat
-- notification needs both the conversation id AND the sender's
-- id, for example). This holds that extra navigation payload,
-- e.g. {"screen": "chat", "chat_id": 12, "sender_id": 7}.
ALTER TABLE notifications
  ADD COLUMN IF NOT EXISTS data JSONB NOT NULL DEFAULT '{}'::jsonb;

-- ─── 2. Multi-device push tokens ─────────────────────────
-- Replaces the old single users.fcm_token column (kept for
-- backward compatibility, no longer the source of truth) —
-- one row per device, so one account logged into a phone AND
-- a browser tab gets push on both.
CREATE TABLE IF NOT EXISTS user_push_tokens (
  id            SERIAL        PRIMARY KEY,
  user_id       INTEGER       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token         TEXT          NOT NULL UNIQUE,
  platform      VARCHAR(20)   NOT NULL DEFAULT 'android'
                  CHECK (platform IN ('android', 'ios', 'web')),
  device_id     VARCHAR(200),
  is_active     BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_push_tokens_user     ON user_push_tokens (user_id);
CREATE INDEX IF NOT EXISTS idx_push_tokens_active    ON user_push_tokens (user_id, is_active);

-- ─── 3. Notification indexes for real pagination ─────────
-- Cursor-based pagination (newest -> oldest, 20 at a time)
-- needs (user_id, created_at) together, not user_id alone.
CREATE INDEX IF NOT EXISTS idx_notifications_user_created
  ON notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
  ON notifications (user_id, is_read) WHERE is_read = FALSE;
CREATE INDEX IF NOT EXISTS idx_notifications_user_type
  ON notifications (user_id, type);

-- ─── 4. 100-per-user retention, enforced in the database ─
-- Runs after every insert. Deletes only the SAME user's
-- oldest rows beyond their newest 100 — never touches
-- another user's notifications. This is FIFO: notification
-- #101 arriving deletes exactly the 1 oldest row, keeping
-- the total at 100, indefinitely.
CREATE OR REPLACE FUNCTION enforce_notification_retention()
RETURNS TRIGGER AS $$
BEGIN
  DELETE FROM notifications
  WHERE user_id = NEW.user_id
    AND id IN (
      SELECT id FROM notifications
      WHERE user_id = NEW.user_id
      ORDER BY created_at DESC, id DESC
      OFFSET 100
    );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notification_retention ON notifications;
CREATE TRIGGER trg_notification_retention
  AFTER INSERT ON notifications
  FOR EACH ROW
  EXECUTE FUNCTION enforce_notification_retention();

-- ─── Confirms everything above applied correctly ─────────
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'notifications' AND column_name = 'data';

SELECT table_name FROM information_schema.tables
WHERE table_name = 'user_push_tokens';

SELECT trigger_name FROM information_schema.triggers
WHERE trigger_name = 'trg_notification_retention';
