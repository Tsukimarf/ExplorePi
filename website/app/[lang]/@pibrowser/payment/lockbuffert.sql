-- =============================================================================
-- ExplorePi — Price Lock Timer, Real-Time Price Lock Store & Automated
--             Buffer Accounting (PostgreSQL 15+)
-- Branch: Tsukimarf-patch-1
-- 8th file in the chain — apply after:
--   schema.sql
--   explorepi_payment_update.sql
--   explorepi_payment_partial_update.sql
--   explorepi_payment_tolerance_update.sql
--   explorepi_webhook_events_schema.sql
--   explorepi_rules_matrix_update.sql
--   explorepi_best_practices_update.sql
--
-- Problem: a payment priced in USD but settled in Pi needs the PI/USD rate
-- held steady for the few minutes between "user sees a price" and "payment
-- completes" — Pi's price can move materially in that window. This adds:
--
--   1. A real-time price snapshot store (simulates/receives a feed).
--   2. Short-TTL price locks — quote a rate, hold it for N seconds, expire
--      automatically if unused.
--   3. Automated buffer accounting — when a locked payment settles, the
--      variance between the locked rate and the rate at settlement is
--      recorded automatically (no manual reconciliation step) against a
--      running buffer balance the platform uses to absorb that drift.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. Real-time price snapshot store
-- =============================================================================
CREATE TABLE IF NOT EXISTS price_snapshots (
    id           BIGSERIAL PRIMARY KEY,
    pair         VARCHAR(20) NOT NULL,            -- e.g. 'PI/USD'
    rate         NUMERIC(18,8) NOT NULL CHECK (rate > 0),  -- quote per 1 base (USD per 1 Pi)
    source       VARCHAR(40) NOT NULL DEFAULT 'feed',
    snapshot_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_price_snapshots_pair_time
    ON price_snapshots (pair, snapshot_at DESC);

COMMENT ON TABLE price_snapshots IS
    'Append-only real-time price feed ingestion. Latest row per pair = current spot rate.';

CREATE OR REPLACE FUNCTION fn_price_ingest(
    p_pair   VARCHAR(20),
    p_rate   NUMERIC(18,8),
    p_source VARCHAR(40) DEFAULT 'feed'
) RETURNS price_snapshots AS $$
DECLARE
    v_row price_snapshots;
BEGIN
    INSERT INTO price_snapshots (pair, rate, source) VALUES (p_pair, p_rate, p_source)
    RETURNING * INTO v_row;
    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_price_current(p_pair VARCHAR(20))
RETURNS NUMERIC(18,8) AS $$
DECLARE
    v_rate NUMERIC(18,8);
BEGIN
    SELECT rate INTO v_rate FROM price_snapshots
    WHERE pair = p_pair ORDER BY snapshot_at DESC LIMIT 1;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'fn_price_current: no price snapshot available for pair %', p_pair;
    END IF;
    RETURN v_rate;
END;
$$ LANGUAGE plpgsql STABLE;

-- =============================================================================
-- 2. Short-TTL price locks
-- =============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'price_lock_status') THEN
        CREATE TYPE price_lock_status AS ENUM ('active', 'expired', 'consumed', 'cancelled');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS price_locks (
    lock_id           VARCHAR(64) PRIMARY KEY DEFAULT ('plock_' || encode(gen_random_bytes(12), 'hex')),
    pair              VARCHAR(20) NOT NULL,
    locked_rate       NUMERIC(18,8) NOT NULL CHECK (locked_rate > 0),
    quote_amount      NUMERIC(18,2) NOT NULL CHECK (quote_amount > 0),   -- e.g. USD price shown to user
    base_amount       NUMERIC(18,7) NOT NULL CHECK (base_amount > 0),    -- Pi amount at locked_rate
    ttl_seconds       INTEGER NOT NULL DEFAULT 300 CHECK (ttl_seconds > 0 AND ttl_seconds <= 900),
    status            price_lock_status NOT NULL DEFAULT 'active',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at        TIMESTAMPTZ NOT NULL,
    consumed_by_payment_id VARCHAR(128),
    consumed_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_price_locks_status_expires ON price_locks (status, expires_at);
CREATE INDEX IF NOT EXISTS idx_price_locks_payment ON price_locks (consumed_by_payment_id);

COMMENT ON TABLE price_locks IS
    'Short-TTL (default 300s, hard cap 900s) rate locks — hold a quoted price steady only long enough to complete checkout.';

-- pgcrypto for gen_random_bytes() used in the lock_id default above.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 2.1 Create a lock — quotes the CURRENT price and holds it for ttl_seconds.
CREATE OR REPLACE FUNCTION fn_price_lock_create(
    p_pair         VARCHAR(20),
    p_quote_amount NUMERIC(18,2),
    p_ttl_seconds  INTEGER DEFAULT 300
) RETURNS price_locks AS $$
DECLARE
    v_rate NUMERIC(18,8);
    v_row  price_locks;
BEGIN
    IF p_ttl_seconds <= 0 OR p_ttl_seconds > 900 THEN
        RAISE EXCEPTION 'fn_price_lock_create: ttl_seconds must be between 1 and 900, got %', p_ttl_seconds;
    END IF;

    v_rate := fn_price_current(p_pair);

    INSERT INTO price_locks (pair, locked_rate, quote_amount, base_amount, ttl_seconds, expires_at)
    VALUES (
        p_pair, v_rate, p_quote_amount, ROUND(p_quote_amount / v_rate, 7),
        p_ttl_seconds, NOW() + make_interval(secs => p_ttl_seconds)
    )
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- 2.2 Lazily expire on read — a lock past its TTL is treated as expired even
-- if the sweep job (2.4) hasn't run yet, so the "short timer" is enforced
-- exactly, not just eventually.
CREATE OR REPLACE FUNCTION fn_price_lock_get(p_lock_id VARCHAR(64))
RETURNS price_locks AS $$
DECLARE
    v_row price_locks;
BEGIN
    SELECT * INTO v_row FROM price_locks WHERE lock_id = p_lock_id FOR UPDATE;

    IF v_row IS NULL THEN
        RAISE EXCEPTION 'fn_price_lock_get: lock % not found', p_lock_id;
    END IF;

    IF v_row.status = 'active' AND v_row.expires_at < NOW() THEN
        UPDATE price_locks SET status = 'expired' WHERE lock_id = p_lock_id
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- 2.3 Consume a lock at payment-creation time — this is the only path that
-- turns a quote into a payment, and it's where the short timer is enforced.
CREATE OR REPLACE FUNCTION fn_price_lock_consume(
    p_lock_id    VARCHAR(64),
    p_payment_id VARCHAR(128)
) RETURNS price_locks AS $$
DECLARE
    v_row price_locks;
BEGIN
    v_row := fn_price_lock_get(p_lock_id);  -- lazily expires if stale

    IF v_row.status <> 'active' THEN
        RAISE EXCEPTION 'fn_price_lock_consume: lock % is % (not active) — quote must be re-requested', p_lock_id, v_row.status;
    END IF;

    UPDATE price_locks
    SET status = 'consumed',
        consumed_by_payment_id = p_payment_id,
        consumed_at = NOW()
    WHERE lock_id = p_lock_id
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- 2.4 Batch sweep for locks nobody read (no request came in to trigger the
-- lazy-expire path) — schedule every ~30-60s via pg_cron or an app cron.
CREATE OR REPLACE FUNCTION fn_price_locks_sweep_expired() RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE price_locks
    SET status = 'expired'
    WHERE status = 'active' AND expires_at < NOW();
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- 2.5 Link payments to the lock that priced them
ALTER TABLE payments ADD COLUMN IF NOT EXISTS price_lock_id VARCHAR(64) REFERENCES price_locks(lock_id);
ALTER TABLE payments ADD COLUMN IF NOT EXISTS buffer_processed BOOLEAN NOT NULL DEFAULT FALSE;

-- =============================================================================
-- 3. Automated buffer accounting
-- =============================================================================
CREATE TABLE IF NOT EXISTS buffer_ledger (
    id               BIGSERIAL PRIMARY KEY,
    payment_id       VARCHAR(128) NOT NULL REFERENCES payments(payment_id),
    lock_id          VARCHAR(64) REFERENCES price_locks(lock_id),
    pair             VARCHAR(20) NOT NULL,
    locked_rate      NUMERIC(18,8) NOT NULL,
    settlement_rate  NUMERIC(18,8) NOT NULL,
    base_amount      NUMERIC(18,7) NOT NULL,        -- Pi amount actually paid
    variance_quote   NUMERIC(18,7) NOT NULL,         -- + = buffer gained, - = buffer absorbed a loss
    recorded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_buffer_ledger_pair_time ON buffer_ledger (pair, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_buffer_ledger_payment ON buffer_ledger (payment_id);

COMMENT ON TABLE buffer_ledger IS
    'One row per settled, price-locked payment — the USD-equivalent variance between the rate quoted to the user and the rate at settlement.';

CREATE TABLE IF NOT EXISTS buffer_balance (
    pair          VARCHAR(20) PRIMARY KEY,
    balance_quote NUMERIC(18,7) NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE buffer_balance IS
    'Running total per pair — how much the platform currently holds in reserve against locked-price drift. A sustained negative trend means locks are underpricing risk.';

-- 3.1 Core accounting function — computes and records the variance, updates
-- the running balance, in one atomic step.
CREATE OR REPLACE FUNCTION fn_buffer_apply_for_payment(p_payment_id VARCHAR(128))
RETURNS buffer_ledger AS $$
DECLARE
    v_payment payments;
    v_lock    price_locks;
    v_settlement_rate NUMERIC(18,8);
    v_variance NUMERIC(18,7);
    v_ledger_row buffer_ledger;
BEGIN
    SELECT * INTO v_payment FROM payments WHERE payment_id = p_payment_id FOR UPDATE;

    IF v_payment IS NULL THEN
        RAISE EXCEPTION 'fn_buffer_apply_for_payment: payment % not found', p_payment_id;
    END IF;

    IF v_payment.price_lock_id IS NULL THEN
        RETURN NULL;  -- not a price-locked payment, nothing to reconcile
    END IF;

    IF v_payment.buffer_processed THEN
        RETURN NULL;  -- already accounted for — idempotent no-op
    END IF;

    SELECT * INTO v_lock FROM price_locks WHERE lock_id = v_payment.price_lock_id;
    v_settlement_rate := fn_price_current(v_lock.pair);

    -- Positive variance: Pi appreciated since lock, buffer gains the delta
    -- on the amount actually paid. Negative: buffer absorbs the shortfall.
    v_variance := ROUND(v_payment.amount_paid * (v_settlement_rate - v_lock.locked_rate), 7);

    INSERT INTO buffer_ledger (payment_id, lock_id, pair, locked_rate, settlement_rate, base_amount, variance_quote)
    VALUES (p_payment_id, v_lock.lock_id, v_lock.pair, v_lock.locked_rate, v_settlement_rate, v_payment.amount_paid, v_variance)
    RETURNING * INTO v_ledger_row;

    INSERT INTO buffer_balance (pair, balance_quote)
    VALUES (v_lock.pair, v_variance)
    ON CONFLICT (pair) DO UPDATE
        SET balance_quote = buffer_balance.balance_quote + EXCLUDED.balance_quote,
            updated_at = NOW();

    UPDATE payments SET buffer_processed = TRUE WHERE payment_id = p_payment_id;

    RETURN v_ledger_row;
END;
$$ LANGUAGE plpgsql;

-- 3.2 Automation — fires the moment a price-locked payment reaches
-- 'completed', so buffer accounting requires no manual/batch step.
CREATE OR REPLACE FUNCTION trg_auto_buffer_on_completion() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'completed' AND OLD.status <> 'completed'
       AND NEW.price_lock_id IS NOT NULL AND NOT NEW.buffer_processed THEN
        PERFORM fn_buffer_apply_for_payment(NEW.payment_id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_payments_auto_buffer ON payments;
CREATE TRIGGER trg_payments_auto_buffer
    AFTER UPDATE ON payments
    FOR EACH ROW
    EXECUTE FUNCTION trg_auto_buffer_on_completion();
-- AFTER UPDATE (not BEFORE) so this runs once the row, including
-- amount_paid/status, is already durably committed to that state.

-- =============================================================================
-- 4. Observability
-- =============================================================================
CREATE OR REPLACE VIEW v_buffer_health AS
SELECT
    pair,
    balance_quote,
    (SELECT COUNT(*) FROM buffer_ledger bl WHERE bl.pair = bb.pair AND bl.recorded_at > NOW() - INTERVAL '24 hours') AS entries_24h,
    (SELECT COALESCE(SUM(variance_quote), 0) FROM buffer_ledger bl WHERE bl.pair = bb.pair AND bl.recorded_at > NOW() - INTERVAL '24 hours') AS net_variance_24h,
    updated_at
FROM buffer_balance bb;

COMMENT ON VIEW v_buffer_health IS 'Current reserve per pair plus 24h drift — alert if net_variance_24h trends negative for several consecutive days.';

GRANT SELECT ON v_buffer_health TO explorepi_readonly;
GRANT SELECT, INSERT, UPDATE ON price_snapshots, price_locks, buffer_ledger, buffer_balance TO explorepi_app;
GRANT EXECUTE ON FUNCTION
    fn_price_ingest, fn_price_current, fn_price_lock_create, fn_price_lock_get,
    fn_price_lock_consume, fn_price_locks_sweep_expired, fn_buffer_apply_for_payment
TO explorepi_app;

COMMIT;

-- =============================================================================
-- 5. SEED / DEMO DATA
-- =============================================================================
SELECT fn_price_ingest('PI/USD', 0.42000000, 'seed');

-- Quote a $5.00 purchase, lock held 120 seconds (short timer):
-- SELECT * FROM fn_price_lock_create('PI/USD', 5.00, 120);
--   -> locked_rate 0.42, base_amount ≈ 11.9047619 Pi, expires in 120s

-- =============================================================================
-- Example usage — full flow:
--
--   -- 1. Feed ingestion (external price source pushes ticks):
--   SELECT fn_price_ingest('PI/USD', 0.4215, 'coingecko');
--
--   -- 2. User starts checkout — quote and lock the price for 3 minutes:
--   SELECT * FROM fn_price_lock_create('PI/USD', 5.00, 180);
--   -- returns lock_id, locked_rate, base_amount (Pi to charge)
--
--   -- 3. Payment created using the locked base_amount, then consume the lock:
--   SELECT fn_payment_get_or_create('pay_xyz', 'u2a', 'uid_1', 'GXXXX...',
--                                    NULL, 11.9047619, 'checkout');
--   SELECT * FROM fn_price_lock_consume('plock_...', 'pay_xyz');
--   UPDATE payments SET price_lock_id = 'plock_...' WHERE payment_id = 'pay_xyz';
--
--   -- 4. Normal payment lifecycle proceeds (approve/complete/partial as usual).
--      The moment status flips to 'completed', trg_payments_auto_buffer fires
--      automatically — no manual reconciliation step.
--
--   -- 5. If the lock expires before consumption, re-quote:
--   SELECT * FROM fn_price_lock_get('plock_...');  -- status = 'expired'
--   SELECT * FROM fn_price_lock_create('PI/USD', 5.00, 180);  -- fresh lock
--
--   -- 6. Monitor the reserve:
--   SELECT * FROM v_buffer_health;
--
--   -- 7. Scheduled sweep (pg_cron example — run every minute):
--   -- SELECT cron.schedule('sweep-price-locks', '* * * * *',
--   --   $$SELECT fn_price_locks_sweep_expired()$$);
-- =============================================================================
