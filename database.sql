-- =============================================================================
-- ExplorePi - Pi Blockchain Database Schema
-- =============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- for fast LIKE searches on addresses

-- -----------------------------------------------------------------------------
-- BLOCKS
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS blocks (
    id               BIGSERIAL PRIMARY KEY,
    sequence         BIGINT        NOT NULL UNIQUE,           -- ledger sequence number
    hash             VARCHAR(64)   NOT NULL UNIQUE,
    prev_hash        VARCHAR(64),
    closed_at        TIMESTAMPTZ   NOT NULL,
    tx_count         INTEGER       NOT NULL DEFAULT 0,
    op_count         INTEGER       NOT NULL DEFAULT 0,
    total_fees       NUMERIC(20,7) NOT NULL DEFAULT 0,        -- in Pi
    base_fee         INTEGER       NOT NULL DEFAULT 100,      -- in stroops
    base_reserve     NUMERIC(20,7) NOT NULL DEFAULT 0.5,
    max_tx_set_size  INTEGER       NOT NULL DEFAULT 500,
    protocol_version SMALLINT      NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_blocks_closed_at  ON blocks (closed_at DESC);
CREATE INDEX idx_blocks_sequence   ON blocks (sequence DESC);

-- -----------------------------------------------------------------------------
-- TRANSACTIONS
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transactions (
    id              BIGSERIAL PRIMARY KEY,
    hash            VARCHAR(64)   NOT NULL UNIQUE,
    block_sequence  BIGINT        NOT NULL REFERENCES blocks (sequence) ON DELETE CASCADE,
    source_account  VARCHAR(128)  NOT NULL,
    fee             INTEGER       NOT NULL DEFAULT 100,        -- in stroops
    fee_account     VARCHAR(128),
    op_count        SMALLINT      NOT NULL DEFAULT 1,
    memo_type       VARCHAR(16),                               -- none | text | id | hash | return
    memo            TEXT,
    status          VARCHAR(16)   NOT NULL DEFAULT 'success',  -- success | failed
    result_code     VARCHAR(64),
    envelope_xdr    TEXT,
    result_xdr      TEXT,
    meta_xdr        TEXT,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    ledger_closed_at TIMESTAMPTZ  NOT NULL
);

CREATE INDEX idx_tx_block        ON transactions (block_sequence DESC);
CREATE INDEX idx_tx_source       ON transactions (source_account);
CREATE INDEX idx_tx_fee_account  ON transactions (fee_account);
CREATE INDEX idx_tx_status       ON transactions (status);
CREATE INDEX idx_tx_closed_at    ON transactions (ledger_closed_at DESC);

-- -----------------------------------------------------------------------------
-- OPERATIONS
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS operations (
    id              BIGSERIAL PRIMARY KEY,
    tx_hash         VARCHAR(64)   NOT NULL REFERENCES transactions (hash) ON DELETE CASCADE,
    block_sequence  BIGINT        NOT NULL,
    op_index        SMALLINT      NOT NULL DEFAULT 0,
    type            VARCHAR(64)   NOT NULL,    -- payment, create_account, manage_offer, etc.
    source_account  VARCHAR(128),
    details         JSONB,                     -- type-specific fields
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    UNIQUE (tx_hash, op_index)
);

CREATE INDEX idx_op_tx           ON operations (tx_hash);
CREATE INDEX idx_op_block        ON operations (block_sequence DESC);
CREATE INDEX idx_op_type         ON operations (type);
CREATE INDEX idx_op_source       ON operations (source_account);
CREATE INDEX idx_op_details      ON operations USING GIN (details);

-- -----------------------------------------------------------------------------
-- ACCOUNTS
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS accounts (
    id               BIGSERIAL PRIMARY KEY,
    address          VARCHAR(128)  NOT NULL UNIQUE,
    balance          NUMERIC(20,7) NOT NULL DEFAULT 0,        -- Pi balance
    sequence_number  BIGINT        NOT NULL DEFAULT 0,
    num_subentries   INTEGER       NOT NULL DEFAULT 0,
    inflation_dest   VARCHAR(128),
    home_domain      VARCHAR(255),
    thresholds       JSONB,                                   -- {low, med, high, master_weight}
    flags            JSONB,                                   -- {auth_required, auth_revocable, auth_immutable}
    signers          JSONB,                                   -- [{key, weight, type}]
    data_entries     JSONB,                                   -- arbitrary key-value managed data
    created_ledger   BIGINT,
    last_modified    BIGINT,
    first_seen_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_accounts_address    ON accounts (address);
CREATE INDEX idx_accounts_balance    ON accounts (balance DESC);
CREATE INDEX idx_accounts_domain     ON accounts (home_domain) WHERE home_domain IS NOT NULL;
CREATE INDEX idx_accounts_updated    ON accounts (updated_at DESC);

-- -----------------------------------------------------------------------------
-- PAYMENTS  (denormalized view of payment-type operations for fast lookup)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payments (
    id              BIGSERIAL PRIMARY KEY,
    op_id           BIGINT        NOT NULL REFERENCES operations (id) ON DELETE CASCADE,
    tx_hash         VARCHAR(64)   NOT NULL,
    block_sequence  BIGINT        NOT NULL,
    from_account    VARCHAR(128)  NOT NULL,
    to_account      VARCHAR(128)  NOT NULL,
    asset_type      VARCHAR(16)   NOT NULL DEFAULT 'native',  -- native | credit_alphanum4 | credit_alphanum12
    asset_code      VARCHAR(12),
    asset_issuer    VARCHAR(128),
    amount          NUMERIC(20,7) NOT NULL,
    memo_type       VARCHAR(16),
    memo            TEXT,
    created_at      TIMESTAMPTZ   NOT NULL
);

CREATE INDEX idx_pay_from       ON payments (from_account);
CREATE INDEX idx_pay_to         ON payments (to_account);
CREATE INDEX idx_pay_asset      ON payments (asset_code, asset_issuer);
CREATE INDEX idx_pay_block      ON payments (block_sequence DESC);
CREATE INDEX idx_pay_created    ON payments (created_at DESC);

-- -----------------------------------------------------------------------------
-- ASSETS
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS assets (
    id              BIGSERIAL PRIMARY KEY,
    asset_type      VARCHAR(16)   NOT NULL,
    asset_code      VARCHAR(12)   NOT NULL,
    asset_issuer    VARCHAR(128)  NOT NULL,
    accounts        INTEGER       NOT NULL DEFAULT 0,         -- holders
    balances        NUMERIC(20,7) NOT NULL DEFAULT 0,
    amount          NUMERIC(20,7) NOT NULL DEFAULT 0,
    num_claimable   INTEGER       NOT NULL DEFAULT 0,
    flags           JSONB,
    home_domain     VARCHAR(255),
    toml_info       JSONB,                                   -- cached .well-known/stellar.toml data
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    UNIQUE (asset_code, asset_issuer)
);

CREATE INDEX idx_assets_code    ON assets (asset_code);
CREATE INDEX idx_assets_issuer  ON assets (asset_issuer);
CREATE INDEX idx_assets_holders ON assets (accounts DESC);

-- -----------------------------------------------------------------------------
-- OFFERS  (DEX)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS offers (
    id              BIGSERIAL PRIMARY KEY,
    offer_id        BIGINT        NOT NULL UNIQUE,
    seller          VARCHAR(128)  NOT NULL,
    selling_code    VARCHAR(12),
    selling_issuer  VARCHAR(128),
    buying_code     VARCHAR(12),
    buying_issuer   VARCHAR(128),
    amount          NUMERIC(20,7) NOT NULL,
    price_n         BIGINT        NOT NULL,
    price_d         BIGINT        NOT NULL,
    price           NUMERIC(20,10) GENERATED ALWAYS AS (price_n::NUMERIC / NULLIF(price_d,0)) STORED,
    flags           SMALLINT      NOT NULL DEFAULT 0,
    last_modified   BIGINT,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_offers_seller   ON offers (seller);
CREATE INDEX idx_offers_selling  ON offers (selling_code, selling_issuer);
CREATE INDEX idx_offers_buying   ON offers (buying_code, buying_issuer);
CREATE INDEX idx_offers_price    ON offers (price);

-- -----------------------------------------------------------------------------
-- CLAIMABLE BALANCES
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS claimable_balances (
    id              BIGSERIAL PRIMARY KEY,
    balance_id      VARCHAR(128)  NOT NULL UNIQUE,
    asset_type      VARCHAR(16)   NOT NULL,
    asset_code      VARCHAR(12),
    asset_issuer    VARCHAR(128),
    amount          NUMERIC(20,7) NOT NULL,
    sponsor         VARCHAR(128),
    claimants       JSONB         NOT NULL DEFAULT '[]',      -- [{destination, predicate}]
    flags           SMALLINT      NOT NULL DEFAULT 0,
    last_modified   BIGINT,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cb_asset    ON claimable_balances (asset_code, asset_issuer);
CREATE INDEX idx_cb_sponsor  ON claimable_balances (sponsor);

-- -----------------------------------------------------------------------------
-- NETWORK STATISTICS  (cached snapshots — written by the crawler periodically)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS network_stats (
    id              BIGSERIAL PRIMARY KEY,
    recorded_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    total_accounts  BIGINT        NOT NULL DEFAULT 0,
    total_txs       BIGINT        NOT NULL DEFAULT 0,
    total_ops       BIGINT        NOT NULL DEFAULT 0,
    total_payments  BIGINT        NOT NULL DEFAULT 0,
    latest_ledger   BIGINT        NOT NULL DEFAULT 0,
    avg_block_time  NUMERIC(10,3),                            -- seconds
    tps_1h          NUMERIC(10,3),                            -- tx/s last 1h
    tps_24h         NUMERIC(10,3),                            -- tx/s last 24h
    fees_24h        NUMERIC(20,7) NOT NULL DEFAULT 0,
    active_accounts_24h BIGINT    NOT NULL DEFAULT 0
);

CREATE INDEX idx_netstats_at ON network_stats (recorded_at DESC);

-- -----------------------------------------------------------------------------
-- CRAWLER STATE  (tracks sync progress per ledger range)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crawler_state (
    id              SERIAL PRIMARY KEY,
    key             VARCHAR(64)   NOT NULL UNIQUE,
    value           TEXT          NOT NULL,
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Seed initial cursor
INSERT INTO crawler_state (key, value) VALUES
  ('last_synced_ledger', '0'),
  ('crawler_version',    '1.0.0'),
  ('network',            'mainnet')
ON CONFLICT (key) DO NOTHING;

-- -----------------------------------------------------------------------------
-- SEARCH CACHE  (pre-computed FTS for accounts and tx hashes)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS search_index (
    id              BIGSERIAL PRIMARY KEY,
    entity_type     VARCHAR(32)   NOT NULL,   -- block | tx | account | asset
    entity_id       TEXT          NOT NULL,   -- hash / address / sequence
    search_vector   TSVECTOR,
    UNIQUE (entity_type, entity_id)
);

CREATE INDEX idx_search_fts    ON search_index USING GIN (search_vector);
CREATE INDEX idx_search_entity ON search_index (entity_type, entity_id);

-- -----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Stroops → Pi
CREATE OR REPLACE FUNCTION stroops_to_pi(stroops BIGINT)
RETURNS NUMERIC(20,7) LANGUAGE SQL IMMUTABLE AS $$
    SELECT stroops::NUMERIC(20,7) / 10000000;
$$;

-- Pi → Stroops
CREATE OR REPLACE FUNCTION pi_to_stroops(pi NUMERIC(20,7))
RETURNS BIGINT LANGUAGE SQL IMMUTABLE AS $$
    SELECT (pi * 10000000)::BIGINT;
$$;

-- Update updated_at automatically
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_accounts_updated
    BEFORE UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER trg_assets_updated
    BEFORE UPDATE ON assets
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER trg_offers_updated
    BEFORE UPDATE ON offers
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();