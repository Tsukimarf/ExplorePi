-- Pi blockchain explorer database schema
-- Models: ledgers (blocks), transactions, operations, accounts, balances, assets

CREATE TABLE ledgers (
    sequence     BIGINT PRIMARY KEY,
    hash         CHAR(64) NOT NULL UNIQUE,
    prev_hash    CHAR(64),
    closed_at    TIMESTAMP NOT NULL,
    tx_count     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE accounts (
    account_id      VARCHAR(56) PRIMARY KEY,
    sequence_number BIGINT NOT NULL DEFAULT 0,
    subentry_count  INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE transactions (
    tx_hash        CHAR(64) PRIMARY KEY,
    ledger_seq     BIGINT NOT NULL REFERENCES ledgers(sequence),
    source_account VARCHAR(56) NOT NULL REFERENCES accounts(account_id),
    fee_paid       INTEGER NOT NULL,
    memo           TEXT,
    result_code    VARCHAR(32) NOT NULL
);

CREATE TABLE operations (
    id             BIGSERIAL PRIMARY KEY,
    tx_hash        CHAR(64) NOT NULL REFERENCES transactions(tx_hash),
    source_account VARCHAR(56) NOT NULL REFERENCES accounts(account_id),
    type           VARCHAR(32) NOT NULL,
    details        JSONB
);

CREATE TABLE assets (
    asset_code VARCHAR(12) PRIMARY KEY,
    issuer     VARCHAR(56),
    type       VARCHAR(16) NOT NULL
);

CREATE TABLE balances (
    id         BIGSERIAL PRIMARY KEY,
    account_id VARCHAR(56) NOT NULL REFERENCES accounts(account_id),
    asset_code VARCHAR(12) NOT NULL REFERENCES assets(asset_code),
    amount     NUMERIC(20, 7) NOT NULL DEFAULT 0,
    UNIQUE (account_id, asset_code)
);

-- Payments: the "payment" subset of operations (type_i = 1 in Horizon),
-- denormalized for fast lookups by from/to account. Mirrors the fields
-- consumed by explorer/payment.jsx (from, to, amount, created_at, type_i).
CREATE TABLE payments (
    id             BIGSERIAL PRIMARY KEY,
    operation_id   BIGINT REFERENCES operations(id),
    tx_hash        CHAR(64) NOT NULL REFERENCES transactions(tx_hash),
    type_i         SMALLINT NOT NULL DEFAULT 1,
    from_account   VARCHAR(56) NOT NULL REFERENCES accounts(account_id),
    to_account     VARCHAR(56) NOT NULL REFERENCES accounts(account_id),
    asset_type     VARCHAR(16) NOT NULL DEFAULT 'native',
    asset_code     VARCHAR(12) REFERENCES assets(asset_code),
    asset_issuer   VARCHAR(56),
    amount         NUMERIC(20, 7) NOT NULL,
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Helpful indexes for explorer lookups
CREATE INDEX idx_transactions_ledger_seq ON transactions(ledger_seq);
CREATE INDEX idx_transactions_source_account ON transactions(source_account);
CREATE INDEX idx_operations_tx_hash ON operations(tx_hash);
CREATE INDEX idx_operations_source_account ON operations(source_account);
CREATE INDEX idx_balances_account_id ON balances(account_id);
CREATE INDEX idx_payments_from_account ON payments(from_account);
CREATE INDEX idx_payments_to_account ON payments(to_account);
CREATE INDEX idx_payments_created_at ON payments(created_at);
