-- ═══════════════════════════════════════════════════════════
--  add_district_column.sql
--
--  Run this against your LIVE Supabase database (SQL Editor).
--  This is a SAFE, additive-only change — it does NOT touch,
--  drop, or reset any existing data. Every current user row
--  simply gets district = '' (empty string) until they save
--  their profile again with a district picked.
--
--  Do NOT run the full gms_supabase_setup.sql against your live
--  database for this — that file DROPS and recreates every
--  table. This file is the correct, non-destructive alternative
--  for adding just this one column to data that already exists.
-- ═══════════════════════════════════════════════════════════

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS district VARCHAR(100) NOT NULL DEFAULT '';

-- Confirms the column now exists and shows current row count
-- (should match your existing user count exactly — nothing lost).
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'users' AND column_name = 'district';

SELECT COUNT(*) AS total_users FROM users;
