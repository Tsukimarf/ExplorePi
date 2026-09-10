-- =============================================================================
-- ExplorePi — Payment Update Database (PostgreSQL 15+)
-- Branch: Tsukimarf-patch-1
-- Extends: database.sql / createPaymen/schema.sql (contracts, sync_state,
--          contract_events, claims) with full Pi Network payment lifecycle
--          tracking — created / approved / completed / cancelled / error.
--
-- Matches the callback flow in:
--   website/.../createPaymen/piSDK.js      (onReadyForServerApproval,
--                                            onReadyForServerCompletion,
--                                            onCancel, onError)
--   website/.../createPaymen/piPayment.js  (approvePayment, completePayment,
--                                            rewardUser)
--   website/.../createPaymen/POST /claim.js
--
-- Feeds:
--   website/app/[lang]/@pibrowser/explorer/payment.jsx  (recent payments table)
--   website/app/[lang]/@pibrowser/stream/payment.jsx    (live payment stream)
--
-- Apply after the base schema:
--   psql -U postgres -d explorepi -f ../../createPaymen/schema.sql
--   psql -U postgres -d explorepi -f paumentv2.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. ENUM — payment lifecycle states
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_status') THEN
        CREATE TYPE payment_status AS ENUM (
            'created',              -- pi.createPayment() called client-side
            'pending_approval',     -- onReadyForServerApproval fired
            'approved',             -- server called pi.approvePayment()
            'pending_completion',   -- onReadyForServerCompletion fired (has txid)
            'completed',            -- server called pi.completePayment()
            'cancelled',            -- onCancel fired / user cancelled in wallet
            'error'                 -- onError fired / server-side failure
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_direction') THEN
        CREATE TYPE payment_direction AS ENUM (
            'u2a',  -- User to App  (createPayment via pi-sdk-js)
            'a2u'   -- App to User  (rewardUser via pi-backend)
        );
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. TABLE — payments (source of truth for the Pi payment lifecycle)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payments (
    id              BIGSERIAL PRIMARY KEY,
    payment_id      VARCHAR(128) NOT NULL UNIQUE,          -- Pi Network paymentId
    direction       payment_direction NOT NULL,
    user_uid        VARCHAR(128) NOT NULL,                 -- Pi user uid
    wallet_addr     VARCHAR(56),                           -- G... Stellar/Pi address
    contract_id     VARCHAR(56) REFERENCES contracts(contract_id) ON DELETE SET NULL,
    amount          NUMERIC(18,7) NOT NULL CHECK (amount > 0),
    memo            VARCHAR(256),
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,    -- { productId, projectId, ... }
    status          payment_status NOT NULL DEFAULT 'created',
    txid            VARCHAR(128),                          -- set at pending_completion/completed
    network         VARCHAR(20) NOT NULL DEFAULT 'pi-mainnet',
    horizon_ledger  BIGINT,                                -- ledger seq once seen on Horizon
    error_message   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    approved_at     TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    cancelled_at    TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_txid_when_completed
        CHECK (status <> 'completed' OR txid IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_payments_user_uid   ON payments(user_uid);
CREATE INDEX IF NOT EXISTS idx_payments_status     ON payments(status);
CREATE INDEX IF NOT EXISTS idx_payments_txid       ON payments(txid);
CREATE INDEX IF NOT EXISTS idx_payments_direction  ON payments(direction);
CREATE INDEX IF NOT EXISTS idx_payments_created_at ON payments(created_at DESC);

COMMENT ON TABLE payments IS 'Full Pi Network payment lifecycle — one row per paymentId, updated in place as status transitions occur.';

-- -----------------------------------------------------------------------------
-- 3. TABLE — payment_status_history (append-only audit trail of every update)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment_status_history (
    id          BIGSERIAL PRIMARY KEY,
    payment_id  VARCHAR(128) NOT NULL REFERENCES payments(payment_id) ON DELETE CASCADE,
    old_status  payment_status,
    new_status  payment_status NOT NULL,
    note        TEXT,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pay_hist_payment_id ON payment_status_history(payment_id);
CREATE INDEX IF NOT EXISTS idx_pay_hist_changed_at ON payment_status_history(changed_at DESC);

-- -----------------------------------------------------------------------------
-- 4. Link claims → payments (claims already exists in createPaymen/schema.sql)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_claims_payment_id'
    ) THEN
        ALTER TABLE claims
            ADD CONSTRAINT fk_claims_payment_id
            FOREIGN KEY (payment_id) REFERENCES payments(payment_id)
            ON DELETE SET NULL;
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 5. TRIGGER — keep updated_at fresh on every row update
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_payments_updated_at ON payments;
CREATE TRIGGER trg_payments_updated_at
    BEFORE UPDATE ON payments
    FOR EACH ROW
    EXECUTE FUNCTION trg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6. TRIGGER — auto-log every status change into payment_status_history
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_log_payment_status_change() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO payment_status_history (payment_id, old_status, new_status, note)
        VALUES (NEW.payment_id, NULL, NEW.status, 'payment created');
    ELSIF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO payment_status_history (payment_id, old_status, new_status, note)
        VALUES (NEW.payment_id, OLD.status, NEW.status,
                 CASE WHEN NEW.status = 'error' THEN NEW.error_message ELSE NULL END);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_payments_status_log ON payments;
CREATE TRIGGER trg_payments_status_log
    AFTER INSERT OR UPDATE ON payments
    FOR EACH ROW
    EXECUTE FUNCTION trg_log_payment_status_change();

-- -----------------------------------------------------------------------------
-- 7. FUNCTIONS — one per lifecycle step, mirroring piSDK.js / piPayment.js
-- -----------------------------------------------------------------------------

-- 7.1 Create a payment record (client called pi.createPayment() / rewardUser())
CREATE OR REPLACE FUNCTION fn_payment_create(
    p_payment_id   VARCHAR(128),
    p_direction    payment_direction,
    p_user_uid     VARCHAR(128),
    p_wallet_addr  VARCHAR(56),
    p_contract_id  VARCHAR(56),
    p_amount       NUMERIC(18,7),
    p_memo         VARCHAR(256),
    p_metadata     JSONB DEFAULT '{}'::jsonb,
    p_network      VARCHAR(20) DEFAULT 'pi-mainnet'
) RETURNS payments AS $$
DECLARE
    v_row payments;
BEGIN
    INSERT INTO payments (
        payment_id, direction, user_uid, wallet_addr, contract_id,
        amount, memo, metadata, network, status
    ) VALUES (
        p_payment_id, p_direction, p_user_uid, p_wallet_addr, p_contract_id,
        p_amount, p_memo, p_metadata, p_network, 'created'
    )
    RETURNING * INTO v_row;
    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- 7.2 onReadyForServerApproval → server calls pi.approvePayment(paymentId)
CREATE OR REPLACE FUNCTION fn_payment_mark_approved(
    p_payment_id VARCHAR(128)
) RETURNS payments AS $$
DECLARE
    v_row payments;
BEGIN
    UPDATE payments
    SET status = 'approved',
        approved_at = NOW()
    WHERE payment_id = p_payment_id
      AND status IN ('created', 'pending_approval')
    RETURNING * INTO v_row;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_payment_mark_approved: payment % not found or in invalid state', p_payment_id;
    END IF;
    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- 7.3 onReadyForServerCompletion(paymentId, txid) → txid now known, awaiting submit
CREATE OR REPLACE FUNCTION fn_payment_mark_pending_completion(
    p_payment_id VARCHAR(128),
    p_txid       VARCHAR(128)
) RETURNS payments AS $$
DECLARE
    v_row payments;
BEGIN
    UPDATE payments
    SET status = 'pending_completion',
        txid   = p_txid
    WHERE payment_id = p_payment_id
      AND status = 'approved'
    RETURNING * INTO v_row;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_payment_mark_pending_completion: payment % not found or not approved', p_payment_id;
    END IF;
    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- 7.4 Server called pi.completePayment(paymentId, txid) successfully
CREATE OR REPLACE FUNCTION fn_payment_mark_completed(
    p_payment_id     VARCHAR(128),
    p_txid           VARCHAR(128),
    p_horizon_ledger BIGINT DEFAULT NULL
) RETURNS payments AS $$
DECLARE
    v_row payments;
BEGIN
    UPDATE payments
    SET status         = 'completed',
        txid           = COALESCE(p_txid, txid),
        horizon_ledger = COALESCE(p_horizon_ledger, horizon_ledger),
        completed_at   = NOW()
    WHERE payment_id = p_payment_id
      AND status IN ('approved', 'pending_completion')
    RETURNING * INTO v_row;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_payment_mark_completed: payment % not found or in invalid state', p_payment_id;
    END IF;
    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- 7.5 onCancel(paymentId) → user cancelled in Pi Wallet
CREATE OR REPLACE FUNCTION fn_payment_mark_cancelled(
    p_payment_id VARCHAR(128),
    p_note       TEXT DEFAULT NULL
) RETURNS payments AS $$
DECLARE
    v_row payments;
BEGIN
    UPDATE payments
    SET status = 'cancelled',
        cancelled_at = NOW(),
        error_message = p_note
    WHERE payment_id = p_payment_id
      AND status NOT IN ('completed', 'cancelled')
    RETURNING * INTO v_row;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_payment_mark_cancelled: payment % not found or already terminal', p_payment_id;
    END IF;
    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- 7.6 onError(error, payment) → any failure at any stage
CREATE OR REPLACE FUNCTION fn_payment_mark_error(
    p_payment_id    VARCHAR(128),
    p_error_message TEXT
) RETURNS payments AS $$
DECLARE
    v_row payments;
BEGIN
    UPDATE payments
    SET status = 'error',
        error_message = p_error_message
    WHERE payment_id = p_payment_id
      AND status <> 'completed'
    RETURNING * INTO v_row;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_payment_mark_error: payment % not found or already completed', p_payment_id;
    END IF;
    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- 7.7 Upsert helper for the Horizon payment stream (explorer/payment.jsx,
--     stream/payment.jsx) — reconciles on-chain payment ops against a
--     pending row by txid, in case an app payment lands on Horizon before
--     the /complete callback is processed.
CREATE OR REPLACE FUNCTION fn_payment_reconcile_from_horizon(
    p_txid          VARCHAR(128),
    p_horizon_ledger BIGINT
) RETURNS INTEGER AS $$
DECLARE
    v_updated INTEGER;
BEGIN
    UPDATE payments
    SET horizon_ledger = p_horizon_ledger,
        status = CASE WHEN status = 'pending_completion' THEN 'completed' ELSE status END,
        completed_at = CASE WHEN status = 'pending_completion' THEN NOW() ELSE completed_at END
    WHERE txid = p_txid;

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN v_updated;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 8. VIEW — combined payment + claim status, for API/UI consumption
--    (backs GET /api/tx/:txid and GET /api/claims/:uid)
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
-- 9. SEED / DEMO DATA — sample payments across the full lifecycle
-- -----------------------------------------------------------------------------
INSERT INTO contracts (contract_id, label, network)
VALUES ('CABC1234567890000000000000000000000000000000000000000000', 'ExplorePi Claim Contract', 'pi-mainnet')
ON CONFLICT (contract_id) DO NOTHING;

SELECT fn_payment_create(
    'pay_demo_completed_001', 'a2u', 'uid_demo_user_001',
    'GDEMO000000000000000000000000000000000000000000000000001',
    'CABC1234567890000000000000000000000000000000000000000000',
    3.1415000, 'ExplorePi daily claim',
    '{"projectId":"rpi-weather-station"}'::jsonb
);
SELECT fn_payment_mark_approved('pay_demo_completed_001');
SELECT fn_payment_mark_pending_completion('pay_demo_completed_001', 'txid_demo_completed_001');
SELECT fn_payment_mark_completed('pay_demo_completed_001', 'txid_demo_completed_001', 48213001);

SELECT fn_payment_create(
    'pay_demo_pending_002', 'u2a', 'uid_demo_user_002',
    'GDEMO000000000000000000000000000000000000000000000000002',
    'CABC1234567890000000000000000000000000000000000000000000',
    5.0000000, 'ExplorePi premium project unlock',
    '{"productId":"prj-ide-theme-pack"}'::jsonb
);
SELECT fn_payment_mark_approved('pay_demo_pending_002');

SELECT fn_payment_create(
    'pay_demo_cancelled_003', 'u2a', 'uid_demo_user_003',
    'GDEMO000000000000000000000000000000000000000000000000003',
    NULL,
    1.5000000, 'ExplorePi tip jar',
    '{}'::jsonb
);
SELECT fn_payment_mark_cancelled('pay_demo_cancelled_003', 'user closed Pi Wallet modal');

SELECT fn_payment_create(
    'pay_demo_error_004', 'a2u', 'uid_demo_user_004',
    'GDEMO000000000000000000000000000000000000000000000000004',
    'CABC1234567890000000000000000000000000000000000000000000',
    3.1415000, 'ExplorePi daily claim',
    '{"projectId":"rpi-home-assistant"}'::jsonb
);
SELECT fn_payment_mark_error('pay_demo_error_004', 'pi.completePayment() failed: insufficient app balance');

INSERT INTO claims (contract_id, user_uid, wallet_addr, amount, payment_id, txid, ledger)
VALUES (
    'CABC1234567890000000000000000000000000000000000000000000',
    'uid_demo_user_001',
    'GDEMO000000000000000000000000000000000000000000000000001',
    3.1415000,
    'pay_demo_completed_001',
    'txid_demo_completed_001',
    48213001
)
ON CONFLICT (txid) DO NOTHING;

COMMIT;

-- =============================================================================
-- Example usage (mirrors the request handlers in POST /claim.js):
--
--   SELECT * FROM fn_payment_create('pay_abc', 'a2u', 'uid_1', 'GXXXX...',
--                                    'CXXXX...', 3.1415, 'daily claim');
--   SELECT * FROM fn_payment_mark_approved('pay_abc');
--   SELECT * FROM fn_payment_mark_pending_completion('pay_abc', 'txid_xyz');
--   SELECT * FROM fn_payment_mark_completed('pay_abc', 'txid_xyz', 48213050);
--
--   -- Full status + claim info for the /api/tx/:txid endpoint:
--   SELECT * FROM v_payment_full_status WHERE txid = 'txid_xyz';
--
--   -- Full audit trail for a payment:
--   SELECT * FROM payment_status_history
--   WHERE payment_id = 'pay_abc' ORDER BY changed_at;
-- =============================================================================
