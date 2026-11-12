-- ═══════════════════════════════════════════════════════════
--  rollback_push_reliability.sql — undoes add_push_reliability.sql
--  Atomic. Restores the token rows the migration deactivated, then
--  removes the objects it created. Deploy the OLD backend first (or the
--  new backend will fail to find idempotency_keys when a client sends an
--  Idempotency-Key header).
-- ═══════════════════════════════════════════════════════════
BEGIN;
DROP INDEX IF EXISTS uq_push_active_user_device;   -- must go first, or re-activating duplicates would violate it

-- Restore rows the migration deactivated (skipped cleanly if the
-- migration never ran, i.e. the backup table doesn't exist).
DO $$
BEGIN
  IF to_regclass('public.push_dedupe_backup') IS NOT NULL THEN
    UPDATE user_push_tokens
       SET is_active = TRUE
     WHERE id IN (SELECT token_id FROM push_dedupe_backup);
  END IF;
END $$;

DROP TABLE IF EXISTS push_dedupe_backup;
DROP TABLE IF EXISTS idempotency_keys;
COMMIT;
