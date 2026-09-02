-- ═══════════════════════════════════════════════════════════
--  add_advance_percent_config.sql
--
--  Run this ONLY IF you already ran add_pricing_system.sql before
--  today. If you haven't, skip this — the updated
--  add_pricing_system.sql already includes this row.
--
--  Safe, additive-only — adds one config row, touches nothing else.
-- ═══════════════════════════════════════════════════════════

INSERT INTO platform_config (key, value, description) VALUES
  ('advance_percent', '25', 'Percentage of a service''s listed price collected as the booking confirmation advance when a provider accepts a request')
ON CONFLICT (key) DO NOTHING;

SELECT key, value FROM platform_config WHERE key = 'advance_percent';
