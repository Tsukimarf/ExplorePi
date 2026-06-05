-- schema.sql
-- Run once to set up the ExplorePi account database

CREATE DATABASE IF NOT EXISTS explorepi
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE explorepi;

-- ── accounts ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS accounts (
  id              VARCHAR(36)      NOT NULL DEFAULT (UUID()),
  wallet_address  VARCHAR(64)      NOT NULL,
  contract_address VARCHAR(64)     NOT NULL,
  created_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_wallet (wallet_address)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ── account_profiles ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS account_profiles (
  id              VARCHAR(36)      NOT NULL DEFAULT (UUID()),
  account_id      VARCHAR(36)      NOT NULL,
  username        VARCHAR(64)          NULL,
  display_name    VARCHAR(128)         NULL,
  bio             TEXT                 NULL,
  avatar_url      VARCHAR(512)         NULL,
  website_url     VARCHAR(512)         NULL,
  twitter_handle  VARCHAR(64)          NULL,
  github_handle   VARCHAR(64)          NULL,
  language        VARCHAR(10)      NOT NULL DEFAULT 'en',
  timezone        VARCHAR(64)      NOT NULL DEFAULT 'UTC',
  is_verified     TINYINT(1)       NOT NULL DEFAULT 0,
  created_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_account (account_id),
  CONSTRAINT fk_profile_account
    FOREIGN KEY (account_id) REFERENCES accounts(id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ── account_metadata ──────────────────────────────────────────────────────────
-- Flexible key-value store for arbitrary on-chain or app metadata
CREATE TABLE IF NOT EXISTS account_metadata (
  id              VARCHAR(36)      NOT NULL DEFAULT (UUID()),
  account_id      VARCHAR(36)      NOT NULL,
  meta_key        VARCHAR(128)     NOT NULL,
  meta_value      TEXT                 NULL,
  source          ENUM('app','chain') NOT NULL DEFAULT 'app',
  created_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_meta (account_id, meta_key),
  CONSTRAINT fk_meta_account
    FOREIGN KEY (account_id) REFERENCES accounts(id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ── audit_log ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
  id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  account_id      VARCHAR(36)          NULL,
  action          VARCHAR(64)      NOT NULL,
  details         JSON                 NULL,
  ip_address      VARCHAR(45)          NULL,
  created_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_account (account_id),
  KEY idx_action  (action),
  KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
