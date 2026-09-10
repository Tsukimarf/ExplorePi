-- Contract registry
CREATE TABLE contracts (
  id           SERIAL PRIMARY KEY,
  contract_id  VARCHAR(56) NOT NULL UNIQUE,  -- C... address (Soroban)
  label        VARCHAR(100),
  network      VARCHAR(20) DEFAULT 'pi-mainnet',
  registered_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sync cursor per contract
CREATE TABLE sync_state (
  contract_id  VARCHAR(56) PRIMARY KEY REFERENCES contracts(contract_id),
  last_ledger  BIGINT NOT NULL DEFAULT 0,
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

-- Raw events dari contract
CREATE TABLE contract_events (
  id           SERIAL PRIMARY KEY,
  contract_id  VARCHAR(56) NOT NULL,
  ledger       BIGINT NOT NULL,
  txhash       VARCHAR(128),
  event_type   VARCHAR(50),        -- e.g. transfer, claim, subscribe
  topics       JSONB,              -- decoded topics array
  value        JSONB,              -- decoded event value
  ingested_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(txhash, ledger, event_type)
);

-- Parsed claim events (ExplorePi-specific)
CREATE TABLE claims (
  id           SERIAL PRIMARY KEY,
  contract_id  VARCHAR(56),
  user_uid     VARCHAR(128),
  wallet_addr  VARCHAR(56),
  amount       NUMERIC(18,7),
  payment_id   VARCHAR(128),
  txid         VARCHAR(128) UNIQUE,
  ledger       BIGINT,
  claimed_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_events_contract ON contract_events(contract_id);
CREATE INDEX idx_events_ledger   ON contract_events(ledger);
CREATE INDEX idx_claims_uid      ON claims(user_uid);
