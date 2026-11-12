-- ═══════════════════════════════════════════════════════════
--  add_message_delivered_status.sql
--
--  Run this against your LIVE Supabase database (SQL Editor).
--  SAFE, additive-only — does not touch, drop, or reset any
--  existing data.
--
--  Adds the missing middle state for WhatsApp-style message
--  ticks: sent (single tick) -> delivered (grey double tick,
--  NEW) -> read (blue double tick, already existed as is_read).
-- ═══════════════════════════════════════════════════════════

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMP DEFAULT NULL;

-- Confirms it applied correctly.
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'messages' AND column_name = 'delivered_at';

SELECT COUNT(*) AS total_messages FROM messages;
