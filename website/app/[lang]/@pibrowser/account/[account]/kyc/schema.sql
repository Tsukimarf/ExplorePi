-- ExplorePi database schema (PostgreSQL 15+)
-- Jalankan: psql -U explorepi -d explorepi -f schema.sql

BEGIN;

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- helper ----------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------- ACCOUNTS ([account] route) ----------
CREATE TABLE IF NOT EXISTS accounts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username      CITEXT NOT NULL UNIQUE
                CHECK (username ~ '^[A-Za-z0-9_.-]{3,32}$'),
  pi_uid        TEXT UNIQUE,                       -- id dari Pi Network (opsional)
  lang          TEXT NOT NULL DEFAULT 'en',        -- segmen [lang]
  status        TEXT NOT NULL DEFAULT 'active'
                CHECK (status IN ('active','suspended','deleted')),
  password_hash TEXT,                              -- argon2id, jangan pernah plaintext
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ
);
CREATE TRIGGER trg_accounts_updated BEFORE UPDATE ON accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS account_profiles (
  account_id   UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  display_name TEXT,
  bio          TEXT,
  avatar_url   TEXT,
  country      TEXT,
  settings     JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON account_profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------- POST-QUANTUM KEYS ----------
-- Hanya PUBLIC key yang disimpan. Secret key ada di KMS/Vault, bukan di database.
CREATE TABLE IF NOT EXISTS pq_keys (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  UUID REFERENCES accounts(id) ON DELETE CASCADE,  -- NULL = kunci sistem
  algorithm   TEXT NOT NULL DEFAULT 'ML-KEM-768',
  version     INT  NOT NULL DEFAULT 1,
  public_key  BYTEA NOT NULL,
  kms_ref     TEXT NOT NULL,                       -- referensi ke secret key di KMS/Vault
  status      TEXT NOT NULL DEFAULT 'active'
              CHECK (status IN ('active','rotated','revoked')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, version)
);
CREATE INDEX IF NOT EXISTS idx_pq_keys_active ON pq_keys(account_id) WHERE status = 'active';

-- Data sensitif terenkripsi (ML-KEM + AES-256-GCM)
CREATE TABLE IF NOT EXISTS account_secrets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  pq_key_id   UUID NOT NULL REFERENCES pq_keys(id),
  field_name  TEXT NOT NULL,                       -- mis. 'email', 'phone'
  kem_ct      BYTEA NOT NULL,                      -- ciphertext KEM
  nonce       BYTEA NOT NULL,
  data        BYTEA NOT NULL,                      -- AES-GCM ciphertext
  blind_index BYTEA,                               -- HMAC untuk pencarian exact-match
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, field_name)
);
CREATE INDEX IF NOT EXISTS idx_secrets_blind ON account_secrets(field_name, blind_index);
CREATE TRIGGER trg_secrets_updated BEFORE UPDATE ON account_secrets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------- SESSIONS ----------
CREATE TABLE IF NOT EXISTS sessions (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  token_hash   BYTEA NOT NULL UNIQUE,              -- simpan hash, bukan token
  user_agent   TEXT,
  ip           INET,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at   TIMESTAMPTZ NOT NULL,
  revoked_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_sessions_account ON sessions(account_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);

-- ---------- WALLET & TRANSAKSI ----------
CREATE TABLE IF NOT EXISTS wallets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  address     TEXT NOT NULL UNIQUE,                -- alamat PUBLIK saja
  label       TEXT,
  is_primary  BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wallet_primary
  ON wallets(account_id) WHERE is_primary;

CREATE TABLE IF NOT EXISTS transactions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tx_hash     TEXT NOT NULL UNIQUE,
  wallet_id   UUID REFERENCES wallets(id) ON DELETE SET NULL,
  direction   TEXT NOT NULL CHECK (direction IN ('in','out')),
  counterparty TEXT,
  amount      NUMERIC(24,8) NOT NULL CHECK (amount >= 0),
  asset       TEXT NOT NULL DEFAULT 'PI',
  status      TEXT NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending','confirmed','failed')),
  memo        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  confirmed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_tx_wallet_time ON transactions(wallet_id, created_at DESC);

-- ---------- PIBROWSER ----------
CREATE TABLE IF NOT EXISTS bookmarks (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  title       TEXT NOT NULL,
  url         TEXT NOT NULL,
  folder      TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, url)
);

CREATE TABLE IF NOT EXISTS browse_history (
  id          BIGSERIAL PRIMARY KEY,
  account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  url         TEXT NOT NULL,
  title       TEXT,
  visited_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_history_account_time
  ON browse_history(account_id, visited_at DESC);

-- ---------- AUDIT LOG (append-only) ----------
CREATE TABLE IF NOT EXISTS audit_logs (
  id          BIGSERIAL PRIMARY KEY,
  account_id  UUID REFERENCES accounts(id) ON DELETE SET NULL,
  action      TEXT NOT NULL,
  detail      JSONB NOT NULL DEFAULT '{}'::jsonb,
  ip          INET,
  signature   BYTEA,                               -- tanda tangan ML-DSA (opsional)
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_account_time ON audit_logs(account_id, created_at DESC);

CREATE OR REPLACE FUNCTION audit_no_change() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'audit_logs bersifat append-only';
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_immutable BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION audit_no_change();

-- ---------- ROLE (least privilege) ----------
-- Ganti password sebelum produksi.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'explorepi_app') THEN
    CREATE ROLE explorepi_app LOGIN PASSWORD 'CHANGE_ME';
  END IF;
END $$;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO explorepi_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO explorepi_app;
REVOKE UPDATE, DELETE ON audit_logs FROM explorepi_app;

COMMIT;
