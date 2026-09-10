-- =============================================================================
-- ExplorePi — Dynamic Tolerance Calculator (PostgreSQL 15+)
-- Branch: Tsukimarf-patch-1
-- Patches: explorepi_payment_update.sql, explorepi_payment_partial_update.sql
--
-- Problem: Pi/Stellar payments can land a few stroops short of the exact
-- amount due (network fee deduction, client-side rounding to 7 decimals,
-- fee-bump differences) or slightly over. Requiring an exact match before
-- marking a payment 'completed' leaves legitimate payments stuck in
-- 'partially_paid' forever. This adds a TOLERANCE that scales with the
-- payment size instead of a single hardcoded constant.
--
-- Apply after the prior two files:
--   psql -U postgres -d explorepi -f schema.sql
--   psql -U postgres -d explorepi -f explorepi_payment_update.sql
--   psql -U postgres -d explorepi -f explorepi_payment_partial_update.sql
--   psql -U postgres -d explorepi -f explorepi_payment_tolerance_update.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. CONFIG TABLE — tunable per network, no redeploy needed to adjust rates
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment_tolerance_config (
    network      VARCHAR(20) PRIMARY KEY,
    min_floor    NUMERIC(18,7) NOT NULL DEFAULT 0.0000100,  -- absolute dust floor
    pct_rate     NUMERIC(9,6)  NOT NULL DEFAULT 0.001000,   -- 0.1% of amount due
    max_cap      NUMERIC(18,7) NOT NULL DEFAULT 0.0100000,  -- hard ceiling
    updated_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_tolerance_bounds
        CHECK (min_floor >= 0 AND pct_rate >= 0 AND max_cap >= min_floor)
);

COMMENT ON TABLE payment_tolerance_config IS
    'Per-network tolerance parameters: tolerance = clamp(amount * pct_rate, min_floor, max_cap).';

INSERT INTO payment_tolerance_config (network, min_floor, pct_rate, max_cap) VALUES
    ('pi-mainnet', 0.0000100, 0.001000, 0.0100000),
    ('pi-testnet', 0.0001000, 0.002000, 0.0500000),  -- looser on testnet
    ('default',    0.0000100, 0.001000, 0.0100000)
ON CONFLICT (network) DO NOTHING;

DROP TRIGGER IF EXISTS trg_tolerance_config_updated_at ON payment_tolerance_config;
CREATE TRIGGER trg_tolerance_config_updated_at
    BEFORE UPDATE ON payment_tolerance_config
    FOR EACH ROW
    EXECUTE FUNCTION trg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 2. FUNCTION — the dynamic tolerance calculator itself
--
--    tolerance = LEAST( GREATEST(amount * pct_rate, min_floor), max_cap )
--
--    - min_floor  -> guarantees small payments still get *some* slack
--                    (percentage of a 0.01 Pi payment would otherwise be ~0)
--    - pct_rate   -> scales slack with payment size (bigger payments can
--                    lose more to fees/rounding in absolute terms)
--    - max_cap    -> stops the percentage term from becoming an exploitable
--                    discount on very large payments
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_calculate_tolerance(
    p_amount  NUMERIC(18,7),
    p_network VARCHAR(20) DEFAULT 'pi-mainnet'
) RETURNS NUMERIC(18,7) AS $$
DECLARE
    v_cfg payment_tolerance_config;
    v_tolerance NUMERIC(18,7);
BEGIN
    SELECT * INTO v_cfg FROM payment_tolerance_config WHERE network = p_network;
    IF NOT FOUND THEN
        SELECT * INTO v_cfg FROM payment_tolerance_config WHERE network = 'default';
    END IF;

    IF p_amount IS NULL OR p_amount < 0 THEN
        RAISE EXCEPTION 'fn_calculate_tolerance: amount must be non-negative, got %', p_amount;
    END IF;

    v_tolerance := LEAST(
        GREATEST(p_amount * v_cfg.pct_rate, v_cfg.min_floor),
        v_cfg.max_cap
    );

    RETURN ROUND(v_tolerance, 7);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION fn_calculate_tolerance IS
    'Returns the allowed shortfall/overpay (in Pi) for a payment of a given size on a given network.';

-- -----------------------------------------------------------------------------
-- 3. payments — columns to record when/how much tolerance was applied
-- -----------------------------------------------------------------------------
ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS tolerance_applied NUMERIC(18,7) NOT NULL DEFAULT 0
        CHECK (tolerance_applied >= 0);
ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS overpaid_amount NUMERIC(18,7) NOT NULL DEFAULT 0
        CHECK (overpaid_amount >= 0);

-- -----------------------------------------------------------------------------
-- 4. Replace the installment trigger to settle against dynamic tolerance
--    instead of requiring amount_paid == amount exactly.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_apply_installment_totals() RETURNS TRIGGER AS $$
DECLARE
    v_total_due    NUMERIC(18,7);
    v_network      VARCHAR(20);
    v_total_paid   NUMERIC(18,7);
    v_tolerance    NUMERIC(18,7);
    v_shortfall    NUMERIC(18,7);
    v_overpaid     NUMERIC(18,7) := 0;
    v_paid_capped  NUMERIC(18,7);
    v_tol_applied  NUMERIC(18,7) := 0;
    v_status       payment_status;
BEGIN
    SELECT amount, network INTO v_total_due, v_network
    FROM payments WHERE payment_id = NEW.payment_id FOR UPDATE;

    IF v_total_due IS NULL THEN
        RAISE EXCEPTION 'trg_apply_installment_totals: payment % does not exist', NEW.payment_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_total_paid
    FROM payment_installments
    WHERE payment_id = NEW.payment_id;

    v_tolerance := fn_calculate_tolerance(v_total_due, v_network);
    v_shortfall := v_total_due - v_total_paid;  -- negative means overpaid

    IF v_shortfall < 0 THEN
        v_overpaid := -v_shortfall;
        IF v_overpaid > v_tolerance THEN
            RAISE EXCEPTION 'trg_apply_installment_totals: payment % overpaid by % which exceeds tolerance % (network %)',
                NEW.payment_id, v_overpaid, v_tolerance, v_network;
        END IF;
        v_paid_capped := v_total_due;      -- cap stored amount_paid at the amount due
        v_status      := 'completed';
        v_tol_applied := 0;
    ELSIF v_shortfall <= v_tolerance THEN
        v_paid_capped := v_total_paid;
        v_status      := 'completed';
        v_tol_applied := v_shortfall;      -- 0 when it landed exact
    ELSIF v_total_paid > 0 THEN
        v_paid_capped := v_total_paid;
        v_status      := 'partially_paid';
    ELSE
        v_paid_capped := 0;
        v_status      := 'pending_completion';
    END IF;

    UPDATE payments
    SET amount_paid       = v_paid_capped,
        overpaid_amount   = v_overpaid,
        tolerance_applied = v_tol_applied,
        status            = v_status,
        txid              = COALESCE(NEW.txid, txid),
        completed_at      = CASE WHEN v_status = 'completed' THEN NOW() ELSE completed_at END
    WHERE payment_id = NEW.payment_id
      AND status NOT IN ('cancelled', 'error');

    IF NOT FOUND THEN
        RAISE EXCEPTION 'trg_apply_installment_totals: payment % is cancelled/error, cannot apply installment', NEW.payment_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- (trigger trg_installments_apply on payment_installments already points at
--  this function name, so no DROP/CREATE TRIGGER needed — CREATE OR REPLACE
--  FUNCTION swaps the body in place.)

-- -----------------------------------------------------------------------------
-- 5. VIEW — surface the tolerance fields
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payment_full_status AS
SELECT
    p.payment_id,
    p.direction,
    p.user_uid,
    p.wallet_addr,
    p.contract_id,
    c.label            AS contract_label,
    p.amount,
    p.amount_paid,
    p.amount_remaining,
    p.tolerance_applied,
    p.overpaid_amount,
    (SELECT COUNT(*) FROM payment_installments pi WHERE pi.payment_id = p.payment_id) AS installment_count,
    p.memo,
    p.status,
    p.txid,
    p.network,
    p.horizon_ledger,
    p.error_message,
    p.created_at,
    p.approved_at,
    p.completed_at,
    p.cancelled_at,
    p.updated_at,
    cl.claimed_at,
    cl.project_id
FROM payments p
LEFT JOIN contracts c ON c.contract_id = p.contract_id
LEFT JOIN claims cl   ON cl.payment_id = p.payment_id;

-- -----------------------------------------------------------------------------
-- 6. SEED / DEMO — a payment that lands just short of exact and still settles
-- -----------------------------------------------------------------------------
SELECT fn_payment_create(
    'pay_demo_tolerance_006', 'a2u', 'uid_demo_user_006',
    'GDEMO000000000000000000000000000000000000000000000000006',
    'CABC1234567890000000000000000000000000000000000000000000',
    10.0000000, 'ExplorePi milestone reward (fee-adjusted payout)',
    '{"projectId":"rpi-doorbell-cam"}'::jsonb
);
SELECT fn_payment_mark_approved('pay_demo_tolerance_006');

-- Tolerance for a 10 Pi mainnet payment: LEAST(GREATEST(10*0.001, 0.00001), 0.01) = 0.01
-- Wallet/network fee shaved off 0.006 Pi — still within the 0.01 tolerance.
SELECT fn_payment_apply_partial('pay_demo_tolerance_006', 'txid_demo_tolerance_006', 9.9940000, 48213250, 'network-fee-adjusted settlement');
-- Result: status = 'completed', amount_paid = 9.9940000, tolerance_applied = 0.0060000

COMMIT;

-- =============================================================================
-- Example usage:
--
--   -- Inspect the tolerance a given payment size would get:
--   SELECT fn_calculate_tolerance(10.0000000, 'pi-mainnet');   -- 0.0100000
--   SELECT fn_calculate_tolerance(0.5000000,  'pi-mainnet');   -- 0.0005000
--   SELECT fn_calculate_tolerance(0.0050000,  'pi-mainnet');   -- 0.0000100 (floor)
--
--   -- Retune a network's tolerance without touching any function:
--   UPDATE payment_tolerance_config
--   SET pct_rate = 0.002000, max_cap = 0.0200000
--   WHERE network = 'pi-mainnet';
--
--   -- Check how a payment settled:
--   SELECT payment_id, status, amount, amount_paid, tolerance_applied, overpaid_amount
--   FROM v_payment_full_status WHERE payment_id = 'pay_demo_tolerance_006';
--
-- Notes:
--   - fn_calculate_tolerance is IMMUTABLE and side-effect-free — safe to call
--     standalone from the API layer to preview a tolerance before settlement.
--   - A shortfall within tolerance is recorded (tolerance_applied > 0) rather
--     than silently discarded, so it's auditable via v_payment_full_status.
--   - An overpay beyond tolerance still raises an exception (money doesn't
--     just vanish) — the API layer should catch this and route to a refund
--     or manual-review flow rather than retry the insert.
-- =============================================================================
