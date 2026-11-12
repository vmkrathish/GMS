-- ═══════════════════════════════════════════════════════════
--  add_pricing_system.sql
--
--  Run this against your LIVE Supabase database (SQL Editor).
--  SAFE, additive-only — does not touch, drop, or reset any
--  existing data.
-- ═══════════════════════════════════════════════════════════

-- ─── 1. Admin-configurable pricing/quality rules ─────────
-- Read by the pricing service at calculation time, not
-- hardcoded — an admin changing 20% -> 15% doesn't need a
-- code change or redeploy.
CREATE TABLE IF NOT EXISTS platform_config (
  key          VARCHAR(100)  PRIMARY KEY,
  value        VARCHAR(200)  NOT NULL,
  description  TEXT,
  updated_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO platform_config (key, value, description) VALUES
  ('max_price_increase_pct', '20', 'Maximum % a provider may raise their price above base, once eligible'),
  ('max_price_decrease_pct', '20', 'Default % GMS reduces a provider''s base price by for poor quality'),
  ('rating_qualification_threshold', '4.5', 'Minimum 3-month average rating required for price-increase eligibility (strictly greater than)'),
  ('quality_period_months', '3', 'Rolling window (months) used to evaluate review quality for pricing eligibility'),
  ('market_general_weight', '0.5', 'Weight given to general/national market price vs locality price when calculating base price (0-1)'),
  ('advance_percent', '25', 'Percentage of a service''s listed price collected as the booking confirmation advance when a provider accepts a request')
ON CONFLICT (key) DO NOTHING;

-- ─── 2. Admin-maintained market price reference data ─────
-- Input to the base-price calculation. city = NULL is the
-- general/national reference; a real city name is a
-- locality-specific reference for the same category+model.
CREATE TABLE IF NOT EXISTS market_price_reference (
  id             SERIAL         PRIMARY KEY,
  category_id    INTEGER        NOT NULL REFERENCES service_categories(id) ON DELETE CASCADE,
  price_unit     VARCHAR(10)    NOT NULL CHECK (price_unit IN ('fixed', 'per_hour', 'per_day')),
  city           VARCHAR(100),
  typical_price  DECIMAL(10,2)  NOT NULL,
  updated_at     TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_by     INTEGER        REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_market_ref_lookup
  ON market_price_reference (category_id, price_unit, city);

-- ─── 3. Platform-controlled price envelope per service ───
CREATE TABLE IF NOT EXISTS pricing_state (
  id                       SERIAL         PRIMARY KEY,
  service_id               INTEGER        NOT NULL UNIQUE
                             REFERENCES services(id) ON DELETE CASCADE,
  base_price               DECIMAL(10,2)  NOT NULL,
  max_allowed_price         DECIMAL(10,2)  NOT NULL,
  price_increase_eligible  BOOLEAN        NOT NULL DEFAULT FALSE,
  last_calculated_at       TIMESTAMP      DEFAULT CURRENT_TIMESTAMP,
  created_at               TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at               TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ─── 4. Full audit trail of every base-price change ──────
CREATE TABLE IF NOT EXISTS price_history (
  id                    SERIAL         PRIMARY KEY,
  service_id            INTEGER        NOT NULL REFERENCES services(id) ON DELETE CASCADE,
  previous_base_price   DECIMAL(10,2),
  new_base_price        DECIMAL(10,2)  NOT NULL,
  change_percent        DECIMAL(6,2),
  reason                VARCHAR(300)   NOT NULL,
  max_allowed_price     DECIMAL(10,2)  NOT NULL,
  triggered_by          VARCHAR(50)    NOT NULL,
  effective_date        TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_price_history_service ON price_history (service_id, effective_date DESC);

-- ─── Confirms everything applied correctly ────────────────
SELECT table_name FROM information_schema.tables
WHERE table_name IN ('platform_config', 'market_price_reference', 'pricing_state', 'price_history')
ORDER BY table_name;

SELECT key, value FROM platform_config ORDER BY key;
