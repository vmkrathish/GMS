-- ═══════════════════════════════════════════════════════════
--  OPTIONAL — NOT part of the push-notification fixes; NOT applied.
--
--  Why this exists: none of the GMS tables have Row Level Security.
--  Supabase exposes every table in the `public` schema through its REST
--  API to the `anon` / `authenticated` roles, so anyone holding the
--  project's public anon key could read tables such as messages,
--  user_push_tokens, notifications, bookings and users. (This app never
--  ships that key and talks to the database only through the FastAPI
--  backend, but the exposure exists at the database level.)
--
--  What it does: enables RLS on every public table, with NO policies =
--  the REST API roles are denied everything. The backend connects as the
--  table-owning `postgres` role, which is not subject to RLS, so the
--  FastAPI app is unaffected (tested: full backend test-suite passes
--  with this applied, connecting as a non-superuser owner).
--
--  Caveats — read before running:
--    • Anything else reading these tables through the Supabase REST API
--      or supabase-js with the anon key (a dashboard, a script, a
--      future client) will start getting empty results. The Flutter app
--      does not do this today.
--    • Supabase Storage is unaffected (it uses its own schema).
--  Undo per table:  ALTER TABLE <t> DISABLE ROW LEVEL SECURITY;
-- ═══════════════════════════════════════════════════════════
DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t.tablename);
    RAISE NOTICE 'RLS enabled on %', t.tablename;
  END LOOP;
END $$;
