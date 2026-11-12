-- ═══════════════════════════════════════════════════
--  GMS — Add location-based recommendation support
--
--  Adds `service_categories.is_remote` — used by the new
--  GET /api/services/recommended endpoint (Home page "Recommended
--  for You") to decide how much weight distance should carry:
--  on-site trades (plumbing, electrical…) get full distance weight,
--  remote-friendly ones (web dev, design, editing…) get little/none.
--
--  No other schema changes needed — this feature reuses the
--  existing users.latitude/longitude (the "Home" pinned location
--  already set via the profile's map picker) and the existing
--  services/users/reviews/bookings tables as-is.
--
--  Safe to re-run.
--  Run:   mysql -u root -p gms_db < add_location_recommendations.sql
-- ═══════════════════════════════════════════════════
USE gms_db;

ALTER TABLE service_categories
  ADD COLUMN IF NOT EXISTS is_remote TINYINT(1) NOT NULL DEFAULT 0
  AFTER sort_order;

UPDATE service_categories SET is_remote = 1
  WHERE name IN (
    'Graphic Design', 'Video Editing', 'Photo Editing',
    'Web Development', 'App Development', 'Digital Marketing',
    'Content Writing', 'Accounting & Tax'
  );

SELECT name, is_remote FROM service_categories WHERE is_remote = 1;
SELECT 'Location recommendation support added ✅' AS status;
