-- ═══════════════════════════════════════════════════════════
--  add_push_reliability_precheck.sql — READ-ONLY. Changes nothing.
--  Run in the Supabase SQL Editor BEFORE add_push_reliability.sql, on
--  the project you intend to migrate. No token values are shown.
-- ═══════════════════════════════════════════════════════════

-- 1. Are you on the database you think you are?
SELECT current_database() AS database,
       current_user       AS connected_as,
       split_part(version(), ' ', 2) AS postgres_version;

-- 2. Prerequisites exist (all must be true)
SELECT 'users table'              AS prerequisite, to_regclass('public.users')              IS NOT NULL AS present
UNION ALL SELECT 'user_push_tokens table',          to_regclass('public.user_push_tokens')  IS NOT NULL
UNION ALL SELECT 'user_push_tokens.device_id',      EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='user_push_tokens' AND column_name='device_id')
UNION ALL SELECT 'user_push_tokens.updated_at',     EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='user_push_tokens' AND column_name='updated_at')
UNION ALL SELECT 'user_push_tokens.is_active',      EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='user_push_tokens' AND column_name='is_active');

-- 3. Already applied? (all false = first run; true = migration is a no-op)
SELECT 'idempotency_keys'              AS object, to_regclass('public.idempotency_keys') IS NOT NULL AS already_exists
UNION ALL SELECT 'uq_push_active_user_device',     EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='uq_push_active_user_device')
UNION ALL SELECT 'uq_idempotency_user_scope_key',  EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='uq_idempotency_user_scope_key');

-- 4. Current token population
SELECT count(*)                                            AS total_tokens,
       count(*) FILTER (WHERE is_active)                   AS active_tokens,
       count(*) FILTER (WHERE is_active AND device_id IS NULL) AS active_without_device_id
  FROM user_push_tokens;

-- 5. What the migration would change: active duplicates per (user, device).
--    Expect 0 rows on a database whose clients never sent device_id.
--    Every row here except the newest per group would be deactivated.
SELECT user_id, device_id, count(*) AS active_rows,
       (count(*) - 1)              AS would_be_deactivated
  FROM user_push_tokens
 WHERE is_active AND device_id IS NOT NULL
 GROUP BY user_id, device_id
HAVING count(*) > 1;

-- 6. Duplicate active rows WITHOUT updated_at (read-only).
--    Older schemas allowed NULL here. The migration treats NULL as the
--    oldest (ties broken by id) and keeps one row per device: the newest
--    by timestamp, or the highest id if no row in the group has one. Before 2026-10-24 the migration failed on
--    them instead (unique-index error, whole transaction rolled back).
SELECT count(*) AS active_duplicates_with_null_updated_at
  FROM user_push_tokens t
 WHERE t.is_active AND t.device_id IS NOT NULL AND t.updated_at IS NULL
   AND EXISTS (SELECT 1 FROM user_push_tokens n
                WHERE n.user_id = t.user_id AND n.device_id = t.device_id
                  AND n.is_active AND n.id <> t.id);
