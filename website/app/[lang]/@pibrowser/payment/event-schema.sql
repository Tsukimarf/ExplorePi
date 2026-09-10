-- =============================================================================
-- ExplorePi — Webhook Events Schema (PostgreSQL 15+)
-- Branch: Tsukimarf-patch-1
-- Patches: explorepi_payment_update.sql, explorepi_payment_partial_update.sql,
--          explorepi_payment_tolerance_update.sql
--
-- Backs webhookProcessor.js's dynamic dispatcher: every inbound webhook is
-- logged here BEFORE dispatch (idempotency guard against Pi's at-least-once
-- delivery / retries) and updated with the outcome AFTER dispatch (audit
-- trail + dead-letter queue for failed events).
--
-- Apply after the prior three files:
--   psql -U postgres -d explorepi -f schema.sql
--   psql -U postgres -d explorepi -f explorepi_payment_update.sql
--   psql -U postgres -d explorepi -f explorepi_payment_partial_update.sql
--   psql -U postgres -d explorepi -f explorepi_payment_tolerance_update.sql
--   psql -U postgres -d explorepi -f explorepi_webhook_events_schema.sql
-- =============================================================================

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'webhook_status') THEN
        CREATE TYPE webhook_status AS ENUM (
            'received',   -- row inserted, dispatch not yet attempted
            'processing', -- dispatch in progress (crash-recovery marker)
            'processed',  -- handler completed successfully
            'ignored',    -- known event type, deliberately no-op'd
            'unhandled',  -- no registered handler for this event.type
            'failed'      -- handler threw; see error_message / retry_count
        );
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS webhook_events (
    id              BIGSERIAL PRIMARY KEY,
    event_id        VARCHAR(128) NOT NULL UNIQUE,   -- provider's dedupe key
    event_type      VARCHAR(80)  NOT NULL,           -- e.g. 'payment.approval'
    source          VARCHAR(40)  NOT NULL DEFAULT 'pi-network',
    payment_id      VARCHAR(128),                    -- denormalized for fast lookup
    payload         JSONB        NOT NULL,
    headers         JSONB,                            -- raw headers minus secrets
    signature_valid BOOLEAN,
    status          webhook_status NOT NULL DEFAULT 'received',
    error_message   TEXT,
    retry_count     INTEGER      NOT NULL DEFAULT 0,
    received_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    processed_at    TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_webhook_events_type       ON webhook_events(event_type);
CREATE INDEX IF NOT EXISTS idx_webhook_events_status     ON webhook_events(status);
CREATE INDEX IF NOT EXISTS idx_webhook_events_payment_id ON webhook_events(payment_id);
CREATE INDEX IF NOT EXISTS idx_webhook_events_received   ON webhook_events(received_at DESC);

COMMENT ON TABLE webhook_events IS
    'Idempotent inbound webhook log — one row per event_id, dispatched dynamically by event_type.';

DROP TRIGGER IF EXISTS trg_webhook_events_updated_at ON webhook_events;
CREATE TRIGGER trg_webhook_events_updated_at
    BEFORE UPDATE ON webhook_events
    FOR EACH ROW
    EXECUTE FUNCTION trg_set_updated_at();

-- -----------------------------------------------------------------------------
-- FUNCTION — atomic "claim" of an event for processing.
-- Returns the row if this call is the one that gets to process it (status
-- was 'received' or 'failed' and retry_count < max), NULL otherwise — this
-- is what makes concurrent/duplicate webhook deliveries safe without an
-- external lock.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_webhook_claim(
    p_event_id    VARCHAR(128),
    p_event_type  VARCHAR(80),
    p_source      VARCHAR(40),
    p_payment_id  VARCHAR(128),
    p_payload     JSONB,
    p_headers     JSONB DEFAULT NULL,
    p_signature_valid BOOLEAN DEFAULT NULL,
    p_max_retries INTEGER DEFAULT 5
) RETURNS webhook_events AS $$
DECLARE
    v_row webhook_events;
BEGIN
    INSERT INTO webhook_events (event_id, event_type, source, payment_id, payload, headers, signature_valid, status)
    VALUES (p_event_id, p_event_type, p_source, p_payment_id, p_payload, p_headers, p_signature_valid, 'processing')
    ON CONFLICT (event_id) DO UPDATE
        SET status = 'processing'
    WHERE webhook_events.status IN ('received', 'failed')
      AND webhook_events.retry_count < p_max_retries
    RETURNING * INTO v_row;

    RETURN v_row;  -- NULL if already processed/processing/unhandled/exhausted retries
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- FUNCTION — record the outcome of dispatch
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_webhook_mark_result(
    p_event_id      VARCHAR(128),
    p_status        webhook_status,
    p_error_message TEXT DEFAULT NULL
) RETURNS webhook_events AS $$
DECLARE
    v_row webhook_events;
BEGIN
    UPDATE webhook_events
    SET status        = p_status,
        error_message = p_error_message,
        processed_at  = CASE WHEN p_status IN ('processed','ignored','unhandled') THEN NOW() ELSE processed_at END,
        retry_count   = CASE WHEN p_status = 'failed' THEN retry_count + 1 ELSE retry_count END
    WHERE event_id = p_event_id
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

COMMIT;

-- =============================================================================
-- Example usage (mirrors webhookProcessor.js):
--
--   SELECT * FROM fn_webhook_claim('evt_123', 'payment.approval', 'pi-network',
--                                   'pay_abc', '{"paymentId":"pay_abc"}'::jsonb);
--   -- if NULL returned -> already handled/in-flight, respond 200 and stop
--
--   SELECT * FROM fn_webhook_mark_result('evt_123', 'processed');
--   SELECT * FROM fn_webhook_mark_result('evt_123', 'failed', 'DB timeout on fn_payment_mark_approved');
--
--   -- Dead-letter queue: events that exhausted retries
--   SELECT * FROM webhook_events WHERE status = 'failed' AND retry_count >= 5;
-- =============================================================================
