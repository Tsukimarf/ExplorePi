-- =============================================================================
-- ExplorePi — Additional Best Practices (PostgreSQL 15+)
-- Branch: Tsukimarf-patch-1
-- 7th file in the chain — apply after:
--   schema.sql
--   explorepi_payment_update.sql
--   explorepi_payment_partial_update.sql
--   explorepi_payment_tolerance_update.sql
--   explorepi_webhook_events_schema.sql
--   explorepi_rules_matrix_update.sql
--
-- Reference: explorepi_best_practices.md (§1 Roles, §2 Observability,
--            §3 Archival, §4 Idempotent creation, §5 Integrity, §6 Perf)
-- =============================================================================

BEGIN;

-- =============================================================================
-- §1 — Least-privilege roles
-- =============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'explorepi_app') THEN
        CREATE ROLE explorepi_app LOGIN PASSWORD NULL NOINHERIT;
        -- Set a real password out-of-band (secrets manager), e.g.:
        --   ALTER ROLE explorepi_app WITH PASSWORD '<from secrets manager>';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'explorepi_readonly') THEN
        CREATE ROLE explorepi_readonly LOGIN PASSWORD NULL NOINHERIT;
    END IF;
END $$;

-- App role: read/write on the operational tables, execute on functions,
-- explicitly NO delete and NO ddl.
GRANT USAGE ON SCHEMA public TO explorepi_app, explorepi_readonly;

GRANT SELECT, INSERT, UPDATE ON
    payments, payment_installments, payment_status_history,
    claims, contracts, sync_state, contract_events,
    webhook_events, payment_tolerance_config, payment_tolerance_tiers,
    payment_status_transitions, webhook_retry_policy
TO explorepi_app;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO explorepi_app;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO explorepi_app;

-- Read-only role: views only, no base tables. Dashboards should never see
-- a raw payments row directly — v_payment_full_status etc. are the contract.
REVOKE ALL ON payments, payment_installments, payment_status_history,
    claims, contracts, webhook_events FROM explorepi_readonly;

GRANT SELECT ON
    v_payment_full_status, v_webhook_dead_letter
TO explorepi_readonly;
-- v_payment_health_metrics / v_stuck_payments / v_webhook_health granted
-- below once created (§2).

COMMENT ON ROLE explorepi_app IS 'Application service role — read/write, no DELETE, no DDL. Used by webhookProcessor.js and the API backend.';
COMMENT ON ROLE explorepi_readonly IS 'Reporting/dashboard role — SELECT on views only, no base table access.';

-- =============================================================================
-- §2 — Observability views
-- =============================================================================
CREATE OR REPLACE VIEW v_payment_health_metrics AS
SELECT
    network,
    COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '24 hours') AS total_24h,
    COUNT(*) FILTER (WHERE status = 'completed' AND created_at > NOW() - INTERVAL '24 hours') AS completed_24h,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE status = 'completed' AND created_at > NOW() - INTERVAL '24 hours')
        / NULLIF(COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '24 hours'), 0),
        2
    ) AS completion_rate_pct_24h,
    ROUND(AVG(EXTRACT(EPOCH FROM (completed_at - created_at)))
          FILTER (WHERE status = 'completed' AND created_at > NOW() - INTERVAL '24 hours'), 1) AS avg_completion_seconds_24h,
    COUNT(*) FILTER (WHERE status = 'partially_paid') AS currently_partially_paid,
    COUNT(*) FILTER (WHERE status = 'pending_completion') AS currently_pending_completion,
    COUNT(*) FILTER (WHERE status = 'error') AS currently_error
FROM payments
GROUP BY network;

COMMENT ON VIEW v_payment_health_metrics IS 'Rolling 24h payment funnel health per network — completion rate, avg time-to-complete, stuck counts.';

CREATE OR REPLACE VIEW v_stuck_payments AS
SELECT
    payment_id, status, network, direction, user_uid, amount, amount_paid, amount_remaining,
    created_at, updated_at,
    NOW() - updated_at AS time_since_last_update
FROM payments
WHERE status IN ('pending_approval', 'approved', 'pending_completion', 'partially_paid')
  AND updated_at < NOW() - INTERVAL '24 hours'
ORDER BY updated_at ASC;

COMMENT ON VIEW v_stuck_payments IS 'Non-terminal payments with no update in 24h+ — feeds the partially_paid-stall escalation rule.';

CREATE OR REPLACE VIEW v_webhook_health AS
SELECT
    event_type,
    COUNT(*) FILTER (WHERE received_at > NOW() - INTERVAL '24 hours') AS total_24h,
    COUNT(*) FILTER (WHERE status = 'processed' AND received_at > NOW() - INTERVAL '24 hours') AS processed_24h,
    COUNT(*) FILTER (WHERE status = 'failed' AND received_at > NOW() - INTERVAL '24 hours') AS failed_24h,
    COUNT(*) FILTER (WHERE status = 'unhandled' AND received_at > NOW() - INTERVAL '24 hours') AS unhandled_24h
FROM webhook_events
GROUP BY event_type;

COMMENT ON VIEW v_webhook_health IS 'Rolling 24h webhook dispatch outcomes per event type, for the retry-policy alert thresholds.';

GRANT SELECT ON v_payment_health_metrics, v_stuck_payments, v_webhook_health TO explorepi_readonly;

-- =============================================================================
-- §3 — Archival, not deletion
-- =============================================================================
CREATE TABLE IF NOT EXISTS payments_archive (LIKE payments INCLUDING ALL);
CREATE TABLE IF NOT EXISTS payment_installments_archive (LIKE payment_installments INCLUDING ALL);
CREATE TABLE IF NOT EXISTS payment_status_history_archive (LIKE payment_status_history INCLUDING ALL);
CREATE TABLE IF NOT EXISTS webhook_events_archive (LIKE webhook_events INCLUDING ALL);

-- Archive tables intentionally carry no FK constraints back to the live
-- schema — they're a standalone cold-storage copy, not a live-referenced table.
ALTER TABLE payments_archive DROP CONSTRAINT IF EXISTS payments_archive_contract_id_fkey;
ALTER TABLE payment_installments_archive DROP CONSTRAINT IF EXISTS payment_installments_archive_payment_id_fkey;

CREATE OR REPLACE FUNCTION fn_archive_completed_payments(
    p_older_than INTERVAL DEFAULT '90 days',
    p_batch_size INTEGER DEFAULT 1000
) RETURNS INTEGER AS $$
DECLARE
    v_moved INTEGER;
BEGIN
    WITH candidates AS (
        SELECT payment_id FROM payments
        WHERE status IN ('completed', 'cancelled')
          AND updated_at < NOW() - p_older_than
        ORDER BY updated_at
        LIMIT p_batch_size
        FOR UPDATE SKIP LOCKED
    ),
    moved_installments AS (
        INSERT INTO payment_installments_archive
        SELECT pi.* FROM payment_installments pi
        JOIN candidates c ON c.payment_id = pi.payment_id
        RETURNING 1
    ),
    moved_history AS (
        INSERT INTO payment_status_history_archive
        SELECT h.* FROM payment_status_history h
        JOIN candidates c ON c.payment_id = h.payment_id
        RETURNING 1
    ),
    moved_payments AS (
        INSERT INTO payments_archive
        SELECT p.* FROM payments p
        JOIN candidates c ON c.payment_id = p.payment_id
        RETURNING p.payment_id
    ),
    deleted_installments AS (
        DELETE FROM payment_installments WHERE payment_id IN (SELECT payment_id FROM moved_payments) RETURNING 1
    ),
    deleted_history AS (
        DELETE FROM payment_status_history WHERE payment_id IN (SELECT payment_id FROM moved_payments) RETURNING 1
    ),
    deleted_payments AS (
        DELETE FROM payments WHERE payment_id IN (SELECT payment_id FROM moved_payments) RETURNING 1
    )
    SELECT COUNT(*) INTO v_moved FROM moved_payments;

    RETURN v_moved;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_archive_completed_payments IS
    'Moves terminal (completed/cancelled) payments older than the cutoff, plus their installments and status history, into the *_archive tables. Batched with SKIP LOCKED for safe concurrent scheduling.';

-- =============================================================================
-- §4 — Idempotent creation
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_payment_get_or_create(
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
    ON CONFLICT (payment_id) DO NOTHING
    RETURNING * INTO v_row;

    IF v_row IS NULL THEN
        SELECT * INTO v_row FROM payments WHERE payment_id = p_payment_id;
    END IF;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_payment_get_or_create IS
    'Same contract as fn_payment_create but safe to call twice with the same payment_id (e.g. a client retry before the first response arrived) — returns the existing row instead of raising a unique violation.';

-- =============================================================================
-- §5 — Additional integrity constraints
-- =============================================================================
ALTER TABLE payments DROP CONSTRAINT IF EXISTS chk_wallet_addr_format;
ALTER TABLE payments
    ADD CONSTRAINT chk_wallet_addr_format
    CHECK (wallet_addr IS NULL OR wallet_addr ~ '^G[A-Z0-9]{55}$');

ALTER TABLE payments DROP CONSTRAINT IF EXISTS chk_contract_id_format;
ALTER TABLE payments
    ADD CONSTRAINT chk_contract_id_format
    CHECK (contract_id IS NULL OR contract_id ~ '^C[A-Z0-9]{55}$');

-- Stellar/Soroban text memos are capped at 28 bytes on-chain; catch an
-- oversized memo here rather than at broadcast time.
ALTER TABLE payments DROP CONSTRAINT IF EXISTS chk_memo_length;
ALTER TABLE payments
    ADD CONSTRAINT chk_memo_length
    CHECK (memo IS NULL OR octet_length(memo) <= 28);

-- =============================================================================
-- §6 — Query performance
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_payments_status_network_created
    ON payments (status, network, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_webhook_events_failed
    ON webhook_events (event_type, received_at DESC)
    WHERE status = 'failed';

COMMIT;

-- =============================================================================
-- §7 — Rules-matrix regression assertions (run manually against staging,
--       NOT part of the transaction above — these are read-only checks).
-- =============================================================================
-- Every combination the transition matrix marks disallowed must reject:
--   SELECT fn_is_transition_allowed('completed', 'pending_completion');  -- expect false
--   SELECT fn_is_transition_allowed('partially_paid', 'cancelled');     -- expect false
--   SELECT fn_is_transition_allowed('cancelled', 'approved');           -- expect false
--
-- Every combination it marks allowed must accept:
--   SELECT fn_is_transition_allowed('approved', 'completed');           -- expect true
--   SELECT fn_is_transition_allowed('error', 'cancelled');              -- expect true
--
-- Tier boundary sanity (values just below/at/above a band edge):
--   SELECT fn_calculate_tolerance(0.9999999,  'pi-mainnet');  -- still in 0-1 band
--   SELECT fn_calculate_tolerance(1.0000000,  'pi-mainnet');  -- now in 1-10 band
--   SELECT fn_calculate_tolerance(9999.0000000, 'pi-mainnet'); -- 100+ band, capped at 0.2
-- =============================================================================
