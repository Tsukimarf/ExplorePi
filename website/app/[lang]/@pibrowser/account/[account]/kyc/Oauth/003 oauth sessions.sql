-- 003_oauth_sessions: login OAuth (mis. Pi Network) + sesi terhubung ke provider

-- Identitas OAuth per akun. Satu akun bisa punya beberapa provider,
-- tapi satu (provider, provider_user_id) hanya milik satu akun.
CREATE TABLE IF NOT EXISTS oauth_accounts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id        UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  provider          TEXT NOT NULL,                 -- mis. 'pi_network', 'google'
  provider_user_id  TEXT NOT NULL,                 -- 'sub'/uid dari provider
  access_token_enc  BYTEA,                         -- simpan terenkripsi (lihat pq-security), bukan plaintext
  refresh_token_enc BYTEA,
  token_expires_at  TIMESTAMPTZ,
  scope             TEXT,
  raw_profile       JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_user_id)
);
CREATE INDEX IF NOT EXISTS idx_oauth_account ON oauth_accounts(account_id);
CREATE TRIGGER trg_oauth_updated BEFORE UPDATE ON oauth_accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- State sementara untuk alur OAuth (CSRF/PKCE), dibuang begitu dipakai.
CREATE TABLE IF NOT EXISTS oauth_states (
  state       TEXT PRIMARY KEY,
  provider    TEXT NOT NULL,
  code_verifier TEXT,                              -- PKCE
  redirect_to TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at  TIMESTAMPTZ NOT NULL DEFAULT now() + interval '10 minutes'
);

-- sessions: tambah penanda provider asal sesi + contoh baris (bukan data asli)
ALTER TABLE sessions
  ADD COLUMN IF NOT EXISTS oauth_account_id UUID REFERENCES oauth_accounts(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS login_method TEXT NOT NULL DEFAULT 'password'
    CHECK (login_method IN ('password', 'oauth'));

COMMENT ON TABLE sessions IS
  'Contoh baris login OAuth:
   INSERT INTO sessions (account_id, token_hash, oauth_account_id, login_method, user_agent, ip, expires_at)
   VALUES (
     ''00000000-0000-0000-0000-000000000000'',      -- accounts.id
     decode(''<sha256-hex-dari-session-token>'',''hex''),
     ''11111111-1111-1111-1111-111111111111'',      -- oauth_accounts.id
     ''oauth'', ''Mozilla/5.0 ...'', ''203.0.113.10'', now() + interval ''7 days''
   );
   Token asli TIDAK disimpan di sini, hanya hash SHA-256-nya.';

-- Kebersihan otomatis state OAuth kedaluwarsa, dipanggil worker Go.
CREATE OR REPLACE FUNCTION purge_expired_oauth_states() RETURNS void AS $$
  DELETE FROM oauth_states WHERE expires_at < now();
$$ LANGUAGE sql;

GRANT SELECT, INSERT, UPDATE, DELETE ON oauth_accounts, oauth_states TO explorepi_app;
