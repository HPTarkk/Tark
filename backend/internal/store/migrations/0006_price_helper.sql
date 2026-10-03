-- Inputs of the admin panel's price helper: one row. The helper only
-- suggests prices; Bazaar charges whatever is typed in its panel.
CREATE TABLE price_helper (
    id                 smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    base_monthly_toman bigint      NOT NULL CHECK (base_monthly_toman > 0),
    adjustment         numeric(8,4) NOT NULL CHECK (adjustment > 0),
    -- Plan id → multiplier of the monthly price, e.g. {"tark_premium_3m": 2.7}.
    multipliers        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    round_to           bigint      NOT NULL CHECK (round_to > 0),
    ending             bigint      NOT NULL CHECK (ending >= 0 AND ending < round_to),
    updated_by         uuid REFERENCES admin_users(id) ON DELETE SET NULL,
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX price_helper_updated_by ON price_helper (updated_by) WHERE updated_by IS NOT NULL;
