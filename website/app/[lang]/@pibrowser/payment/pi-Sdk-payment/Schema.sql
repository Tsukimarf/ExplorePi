-- =====================================================================
-- ExplorePi | @pibrowser/payment module
-- PostgreSQL schema: claims, payments, webhook_events
-- Target: PostgreSQL 14+
-- =====================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS pibrowser_payment;
SET search_path TO pibrowser_payment, public;

-- ---------------------------------------------------------------------
-- ENUM types
-- ---------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE payment_status AS ENUM (
        'created', 'pending', 'submitted', 'confirmed',
        'completed', 'cancelled', 'expired', 'failed', 'refunded'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE claim_status AS ENUM (
        'open', 'locked', 'claimed', 'released', 'expired'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------
-- claims: reservation of a payable amount against a Pi wallet before
-- the Pi payment flow (piSDK.createPayment) is invoked client-side
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS claims (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pi_uid              TEXT NOT NULL,               -- Pi Network user id (from pi-sdk-js auth)
    pi_username         TEXT,
    wallet_address      TEXT NOT NULL,
    amount_pi           NUMERIC(20, 7) NOT NULL CHECK (amount_pi > 0),
    memo                TEXT,
    metadata            JSONB DEFAULT '{}'::jsonb,
    status              claim_status NOT NULL DEFAULT 'open',
    expires_at          TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '15 minutes'),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_claims_pi_uid ON claims (pi_uid);
CREATE INDEX IF NOT EXISTS idx_claims_status ON claims (status);
CREATE INDEX IF NOT EXISTS idx_claims_expires ON claims (expires_at) WHERE status = 'open';

-- ---------------------------------------------------------------------
-- payments: mirrors Pi Platform payment lifecycle
-- (created -> pending -> submitted -> confirmed -> completed)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payments (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id            UUID REFERENCES claims(id) ON DELETE SET NULL,
    pi_payment_id       TEXT UNIQUE,                 -- id returned by Pi Platform API
    pi_uid              TEXT NOT NULL,
    pi_username         TEXT,
    to_address          TEXT NOT NULL,
    amount_requested    NUMERIC(20, 7) NOT NULL CHECK (amount_requested > 0),
    amount_paid         NUMERIC(20, 7) DEFAULT 0,
    tolerance_bps       INTEGER NOT NULL DEFAULT 50, -- 0.50% default under/over-pay tolerance
    tx_id               TEXT,                        -- Stellar/Soroban transaction hash
    memo                TEXT,
    status              payment_status NOT NULL DEFAULT 'created',
    status_history      JSONB NOT NULL DEFAULT '[]'::jsonb,
    error_reason        TEXT,
    lang                TEXT NOT NULL DEFAULT 'en',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_payments_pi_uid ON payments (pi_uid);
CREATE INDEX IF NOT EXISTS idx_payments_status ON payments (status);
CREATE INDEX IF NOT EXISTS idx_payments_pi_payment_id ON payments (pi_payment_id);
CREATE INDEX IF NOT EXISTS idx_payments_tx_id ON payments (tx_id);

-- Enforced status-transition matrix (mirrors explorepi_rules_matrix_update.sql pattern)
CREATE OR REPLACE FUNCTION fn_validate_payment_transition()
RETURNS TRIGGER AS $$
DECLARE
    allowed BOOLEAN := FALSE;
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    allowed := (OLD.status, NEW.status) IN (
        ('created', 'pending'), ('created', 'cancelled'), ('created', 'expired'),
        ('pending', 'submitted'), ('pending', 'cancelled'), ('pending', 'expired'),
        ('submitted', 'confirmed'), ('submitted', 'failed'),
        ('confirmed', 'completed'), ('confirmed', 'failed'),
        ('completed', 'refunded')
    );

    IF NOT allowed THEN
        RAISE EXCEPTION 'Invalid payment status transition: % -> %', OLD.status, NEW.status;
    END IF;

    NEW.status_history := OLD.status_history || jsonb_build_object(
        'from', OLD.status, 'to', NEW.status, 'at', now()
    );
    NEW.updated_at := now();
    IF NEW.status = 'completed' THEN
        NEW.completed_at := now();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_payment_transition ON payments;
CREATE TRIGGER trg_validate_payment_transition
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION fn_validate_payment_transition();

-- ---------------------------------------------------------------------
-- webhook_events: idempotency log for Pi Platform server-to-server
-- webhooks (payment.pending, payment.submitted, payment.completed, ...)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS webhook_events (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id            TEXT NOT NULL UNIQUE,        -- Pi Platform event id, dedupe key
    event_type          TEXT NOT NULL,
    pi_payment_id       TEXT,
    payload             JSONB NOT NULL,
    processed           BOOLEAN NOT NULL DEFAULT FALSE,
    processed_at        TIMESTAMPTZ,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_webhook_events_type ON webhook_events (event_type);
CREATE INDEX IF NOT EXISTS idx_webhook_events_payment ON webhook_events (pi_payment_id);

-- Idempotent claim of a webhook event: returns TRUE only the first time
-- a given event_id is seen, so retried webhook deliveries are no-ops.
CREATE OR REPLACE FUNCTION fn_webhook_claim(p_event_id TEXT, p_event_type TEXT,
                                             p_pi_payment_id TEXT, p_payload JSONB)
RETURNS BOOLEAN AS $$
DECLARE
    inserted BOOLEAN := FALSE;
BEGIN
    INSERT INTO webhook_events (event_id, event_type, pi_payment_id, payload)
    VALUES (p_event_id, p_event_type, p_pi_payment_id, p_payload)
    ON CONFLICT (event_id) DO NOTHING;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    RETURN inserted > 0;
END;
$$ LANGUAGE plpgsql;

-- Dynamic under/over-pay tolerance check
CREATE OR REPLACE FUNCTION fn_within_tolerance(p_requested NUMERIC, p_paid NUMERIC, p_bps INTEGER)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN ABS(p_paid - p_requested) <= (p_requested * p_bps / 10000.0);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Least-privilege role for the payment API service
DO $$ BEGIN
    CREATE ROLE pibrowser_payment_svc LOGIN PASSWORD 'change_me_in_env';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

GRANT USAGE ON SCHEMA pibrowser_payment TO pibrowser_payment_svc;
GRANT SELECT, INSERT, UPDATE ON claims, payments, webhook_events TO pibrowser_payment_svc;
GRANT EXECUTE ON FUNCTION fn_webhook_claim, fn_within_tolerance TO pibrowser_payment_svc;

-- Observability view
CREATE OR REPLACE VIEW v_payment_funnel AS
SELECT
    date_trunc('day', created_at) AS day,
    status,
    lang,
    count(*) AS n,
    sum(amount_requested) AS total_requested,
    sum(amount_paid) AS total_paid
FROM payments
GROUP BY 1, 2, 3
ORDER BY 1 DESC;

COMMIT;
