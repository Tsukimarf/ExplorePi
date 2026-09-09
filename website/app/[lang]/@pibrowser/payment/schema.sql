-- =============================================================================
-- ExplorePi — Partial Payment Update (PostgreSQL 15+)
-- Branch: Tsukimarf-patch-1
-- Patches: explorepi_payment_update.sql (payments, payment_status_history,
--          fn_payment_* functions, v_payment_full_status)
--
-- Adds support for a payment being settled across MULTIPLE on-chain
-- transactions (installments) instead of a single completePayment() call —
-- e.g. large A2U rewards split into chunks, or a U2A purchase the user pays
-- down over several Pi Wallet confirmations.
--
-- Apply after both prior files:
--   psql -U postgres -d explorepi -f schema.sql
--   psql -U postgres -d explorepi -f explorepi_payment_update.sql
--   psql -U postgres -d explorepi -f explorepi_payment_partial_update.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. New enum value — must run outside an explicit transaction block
--    (PostgreSQL forbids using a value added by ALTER TYPE ... ADD VALUE
--    within the same transaction it was added in).
-- -----------------------------------------------------------------------------
ALTER TYPE payment_status ADD VALUE IF NOT EXISTS 'partially_paid' AFTER 'pending_completion';

-- -----------------------------------------------------------------------------
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. payments — track how much of the total has actually been paid
-- -----------------------------------------------------------------------------
ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS amount_paid NUMERIC(18,7) NOT NULL DEFAULT 0
        CHECK (amount_paid >= 0);

ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS amount_remaining NUMERIC(18,7)
        GENERATED ALWAYS AS (amount - amount_paid) STORED;

-- Guard against a payment somehow ending up overpaid by direct UPDATEs
ALTER TABLE payments
    DROP CONSTRAINT IF EXISTS chk_amount_paid_not_over;
ALTER TABLE payments
    ADD CONSTRAINT chk_amount_paid_not_over CHECK (amount_paid <= amount);

-- -----------------------------------------------------------------------------
-- 2. payment_installments — one row per partial on-chain transaction
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment_installments (
    id              BIGSERIAL PRIMARY KEY,
    payment_id      VARCHAR(128) NOT NULL REFERENCES payments(payment_id) ON DELETE CASCADE,
    txid            VARCHAR(128) NOT NULL UNIQUE,
    amount          NUMERIC(18,7) NOT NULL CHECK (amount > 0),
    horizon_ledger  BIGINT,
    note            TEXT,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_installments_payment_id ON payment_installments(payment_id);
CREATE INDEX IF NOT EXISTS idx_installments_received_at ON payment_installments(received_at DESC);

COMMENT ON TABLE payment_installments IS 'Individual partial-payment transactions applied against a payments row.';

-- -----------------------------------------------------------------------------
-- 3. TRIGGER — recompute amount_paid / status whenever an installment lands
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_apply_installment_totals() RETURNS TRIGGER AS $$
DECLARE
    v_total_due   NUMERIC(18,7);
    v_total_paid  NUMERIC(18,7);
    v_status      payment_status;
BEGIN
    SELECT amount INTO v_total_due FROM payments WHERE payment_id = NEW.payment_id FOR UPDATE;

    IF v_total_due IS NULL THEN
        RAISE EXCEPTION 'trg_apply_installment_totals: payment % does not exist', NEW.payment_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_total_paid
    FROM payment_installments
    WHERE payment_id = NEW.payment_id;

    IF v_total_paid > v_total_due THEN
        RAISE EXCEPTION 'trg_apply_installment_totals: installment total % exceeds amount due % for payment %',
            v_total_paid, v_total_due, NEW.payment_id;
    END IF;

    v_status := CASE
        WHEN v_total_paid >= v_total_due THEN 'completed'
        WHEN v_total_paid > 0            THEN 'partially_paid'
        ELSE 'pending_completion'
    END;

    UPDATE payments
    SET amount_paid  = v_total_paid,
        status       = v_status,
        txid         = COALESCE(NEW.txid, txid),
        completed_at = CASE WHEN v_status = 'completed' THEN NOW() ELSE completed_at END
    WHERE payment_id = NEW.payment_id
      AND status NOT IN ('cancelled', 'error');

    IF NOT FOUND THEN
        RAISE EXCEPTION 'trg_apply_installment_totals: payment % is cancelled/error, cannot apply installment', NEW.payment_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_installments_apply ON payment_installments;
CREATE TRIGGER trg_installments_apply
    AFTER INSERT ON payment_installments
    FOR EACH ROW
    EXECUTE FUNCTION trg_apply_installment_totals();

-- -----------------------------------------------------------------------------
-- 4. FUNCTION — convenience wrapper to record a partial payment
--    (mirrors calling completePayment() for one chunk of a larger payment)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_payment_apply_partial(
    p_payment_id     VARCHAR(128),
    p_txid           VARCHAR(128),
    p_amount         NUMERIC(18,7),
    p_horizon_ledger BIGINT DEFAULT NULL,
    p_note           TEXT DEFAULT NULL
) RETURNS payments AS $$
DECLARE
    v_row payments;
BEGIN
    INSERT INTO payment_installments (payment_id, txid, amount, horizon_ledger, note)
    VALUES (p_payment_id, p_txid, p_amount, p_horizon_ledger, p_note);

    SELECT * INTO v_row FROM payments WHERE payment_id = p_payment_id;
    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 5. VIEW — refresh to surface paid/remaining + installment count
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
-- 6. SEED / DEMO DATA — a payment settled across three partial installments
-- -----------------------------------------------------------------------------
SELECT fn_payment_create(
    'pay_demo_partial_005', 'a2u', 'uid_demo_user_005',
    'GDEMO000000000000000000000000000000000000000000000000005',
    'CABC1234567890000000000000000000000000000000000000000000',
    9.0000000, 'ExplorePi milestone reward (split payout)',
    '{"projectId":"rpi-security-cam"}'::jsonb
);
SELECT fn_payment_mark_approved('pay_demo_partial_005');

SELECT fn_payment_apply_partial('pay_demo_partial_005', 'txid_demo_partial_005_a', 3.0000000, 48213101, 'installment 1/3');
SELECT fn_payment_apply_partial('pay_demo_partial_005', 'txid_demo_partial_005_b', 3.0000000, 48213144, 'installment 2/3');
-- Status after these two: 'partially_paid', amount_paid = 6.0000000, amount_remaining = 3.0000000

SELECT fn_payment_apply_partial('pay_demo_partial_005', 'txid_demo_partial_005_c', 3.0000000, 48213190, 'installment 3/3 — final');
-- Status after final installment: 'completed', amount_paid = 9.0000000, amount_remaining = 0

COMMIT;

-- =============================================================================
-- Example usage:
--
--   -- Record a partial payment against an existing, approved payment:
--   SELECT * FROM fn_payment_apply_partial('pay_abc', 'txid_chunk_1', 2.5000000, 48213200);
--
--   -- Check progress:
--   SELECT payment_id, status, amount, amount_paid, amount_remaining, installment_count
--   FROM v_payment_full_status WHERE payment_id = 'pay_abc';
--
--   -- Full installment breakdown:
--   SELECT * FROM payment_installments WHERE payment_id = 'pay_abc' ORDER BY received_at;
--
-- Notes:
--   - amount_remaining is a GENERATED column — never set it directly.
--   - Inserting directly into payment_installments (bypassing the wrapper
--     function) still works correctly: trg_installments_apply recalculates
--     totals and status regardless of how the row was inserted.
--   - Attempting to apply installments that would exceed the payment's total
--     `amount` raises an exception rather than silently overpaying.
--   - Applying an installment to a 'cancelled' or 'error' payment raises an
--     exception — reopen the payment (e.g. reset status) before retrying.
-- =============================================================================
