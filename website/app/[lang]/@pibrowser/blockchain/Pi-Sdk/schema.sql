-- =============================================================================
-- @pibrowser/blockchain — database schema
-- New standalone database/ folder for this module (mirrors createPaymen/ convention)
-- MySQL 8+
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Chain registry (drives chain selector UI; mirrors lib/piSDK.js CHAINS map)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS blockchain_chains (
  chain_id      VARCHAR(32)  NOT NULL PRIMARY KEY,   -- 'pi' | 'solana' | 'ethereum'
  kind          VARCHAR(32)  NOT NULL,               -- 'stellar-soroban' | 'solana' | 'evm'
  label         VARCHAR(64)  NOT NULL,
  network       VARCHAR(32)  NOT NULL,
  rpc_url       VARCHAR(255) NULL,
  is_enabled    TINYINT(1)   NOT NULL DEFAULT 1,
  sort_order    SMALLINT     NOT NULL DEFAULT 0,
  created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- Cached chain snapshots (short-TTL, avoids hammering RPC on every page load)
CREATE TABLE IF NOT EXISTS blockchain_snapshot_cache (
  chain_id      VARCHAR(32)  NOT NULL,
  payload_json  JSON         NOT NULL,
  fetched_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at    TIMESTAMP    NOT NULL,
  PRIMARY KEY (chain_id),
  CONSTRAINT fk_snapshot_chain FOREIGN KEY (chain_id)
    REFERENCES blockchain_chains(chain_id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- i18n — reuses the languages table from explorepi_i18n_schema.sql if present,
-- otherwise self-creates so this folder works standalone.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS languages (
  code          VARCHAR(10)  NOT NULL PRIMARY KEY,   -- en, id, zh-CN, ko, vi, ru, es, pt
  name_native   VARCHAR(64)  NOT NULL,
  is_active     TINYINT(1)   NOT NULL DEFAULT 1
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS translation_namespaces (
  namespace     VARCHAR(64)  NOT NULL PRIMARY KEY
) ENGINE=InnoDB;

INSERT IGNORE INTO translation_namespaces (namespace) VALUES ('blockchain');

CREATE TABLE IF NOT EXISTS translations (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  namespace     VARCHAR(64)  NOT NULL,
  lang_code     VARCHAR(10)  NOT NULL,
  key_path      VARCHAR(191) NOT NULL,   -- e.g. 'nav.blockchain.title'
  value         TEXT         NOT NULL,
  content_hash  CHAR(64)     NOT NULL,   -- sha256(value), used by sync_translations.py
  updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_translation (namespace, lang_code, key_path),
  CONSTRAINT fk_translation_ns FOREIGN KEY (namespace)
    REFERENCES translation_namespaces(namespace) ON DELETE CASCADE,
  CONSTRAINT fk_translation_lang FOREIGN KEY (lang_code)
    REFERENCES languages(code) ON DELETE CASCADE,
  INDEX idx_translations_lookup (namespace, lang_code)
) ENGINE=InnoDB;
