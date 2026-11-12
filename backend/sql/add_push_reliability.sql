-- ═══════════════════════════════════════════════════════════
--  add_push_reliability.sql  — ADDITIVE, atomic, safe to run repeatedly
--
--  Supports the push-notification reliability fixes:
--    1. idempotency_keys           — a retried POST/PUT (network timeout,
--                                    Render cold start) returns the stored
--                                    result instead of creating a second
--                                    message/booking and a second push.
--    2. uq_push_active_user_device — at most ONE active push token per
--                                    (user, device), enforced by the DB.
--
--  HOW TO RUN (Supabase → SQL Editor, on the intended project):
--    a. Run add_push_reliability_precheck.sql first (read-only) and read
--       what it reports.
--    b. Run THIS file once. It is one transaction: all of it applies or
--       none of it does.
--    c. Deploy the matching backend afterwards.
--  To undo: rollback_push_reliability.sql.
--
--  What it changes in existing data: ONLY pre-existing duplicate ACTIVE
--  tokens for the same (user, device_id) — the older ones are set
--  is_active = FALSE (never deleted) and their ids are recorded in
--  push_dedupe_backup so the rollback can restore them. Rows without a
--  device_id (every row written by older app versions) are untouched.
-- ═══════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. Idempotency keys ────────────────────────────────────
CREATE TABLE IF NOT EXISTS idempotency_keys (
  id           BIGSERIAL    PRIMARY KEY,
  user_id      INTEGER      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  scope        VARCHAR(60)  NOT NULL,
  key          VARCHAR(100) NOT NULL,
  status_code  INTEGER,
  response     JSONB,
  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_idempotency_user_scope_key
  ON idempotency_keys (user_id, scope, key);
CREATE INDEX IF NOT EXISTS ix_idempotency_keys_created_at
  ON idempotency_keys (created_at);

-- This table stores copies of chat/booking API responses. Supabase
-- exposes every public table over its REST API, so lock it down: RLS on
-- with NO policies = denied to the anon/authenticated API roles. The
-- backend connects as the table-owning `postgres` role, which is not
-- subject to RLS, so the app is unaffected.
ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;

-- ─── 2. One ACTIVE token per user + device ──────────────────
-- Record exactly which rows step 2b will deactivate (for rollback).
CREATE TABLE IF NOT EXISTS push_dedupe_backup (
  token_id    INTEGER   PRIMARY KEY,
  recorded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE push_dedupe_backup ENABLE ROW LEVEL SECURITY;

-- 2a. If a user somehow has several active rows for the same device,
--     keep the most recently updated one and mark the rest for
--     deactivation (needed so the unique index below can be created).
INSERT INTO push_dedupe_backup (token_id)
SELECT t.id
  FROM user_push_tokens t
 WHERE t.is_active
   AND t.device_id IS NOT NULL
   AND EXISTS (
         SELECT 1 FROM user_push_tokens n
          WHERE n.user_id   = t.user_id
            AND n.device_id = t.device_id
            AND n.is_active
            -- NULL updated_at (possible on older schemas) counts as
            -- oldest; ties fall back to id. Without COALESCE a NULL made
            -- the comparison NULL, the duplicate survived, and the
            -- unique index below aborted the whole migration.
            AND (COALESCE(n.updated_at, '-infinity'::timestamp), n.id)
              > (COALESCE(t.updated_at, '-infinity'::timestamp), t.id)
       )
ON CONFLICT (token_id) DO NOTHING;

-- 2b. Deactivate (never delete) them.
UPDATE user_push_tokens
   SET is_active = FALSE
 WHERE id IN (SELECT token_id FROM push_dedupe_backup)
   AND is_active;

CREATE UNIQUE INDEX IF NOT EXISTS uq_push_active_user_device
  ON user_push_tokens (user_id, device_id)
  WHERE is_active AND device_id IS NOT NULL;

COMMIT;

-- ─── Confirms everything above applied ──────────────────────
SELECT 'idempotency_keys exists'      AS check, to_regclass('public.idempotency_keys') IS NOT NULL AS ok
UNION ALL
SELECT 'idempotency_keys RLS enabled', relrowsecurity FROM pg_class WHERE oid = 'public.idempotency_keys'::regclass
UNION ALL
SELECT 'uq_push_active_user_device',   EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_push_active_user_device')
UNION ALL
SELECT 'uq_idempotency_user_scope_key', EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_idempotency_user_scope_key');
