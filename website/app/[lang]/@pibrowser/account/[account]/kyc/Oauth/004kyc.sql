-- 004_kyc: status verifikasi untuk halaman .../account/[account]/kyc
-- Sesuaikan kolom ini dengan field form KYC di frontend Anda.

CREATE TABLE IF NOT EXISTS kyc_verifications (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      UUID NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
  status          TEXT NOT NULL DEFAULT 'unverified'
                  CHECK (status IN ('unverified','pending','verified','rejected')),
  provider        TEXT,                            -- mis. 'pi_kyc', vendor KYC pihak ketiga
  provider_ref    TEXT,                             -- id verifikasi di sisi provider
  document_type   TEXT,                             -- 'passport','national_id', dst.
  submitted_at    TIMESTAMPTZ,
  reviewed_at     TIMESTAMPTZ,
  rejection_reason TEXT,
  -- Data identitas sensitif (nama lengkap, no. dokumen) JANGAN disimpan plaintext di sini.
  -- Enkripsi lewat service pq-security dan simpan hasilnya di account_secrets,
  -- atau tambah kolom *_enc BYTEA yang terisi dari crypto.py bila perlu terhubung langsung.
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_kyc_status ON kyc_verifications(status);
CREATE TRIGGER trg_kyc_updated BEFORE UPDATE ON kyc_verifications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


GRANT SELECT, INSERT, UPDATE ON kyc_verifications TO explorepi_app;
