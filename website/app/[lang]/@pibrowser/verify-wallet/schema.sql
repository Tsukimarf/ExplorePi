-- ExplorePi i18n / language database
-- Version: 1 (explorepi_i18n_schema.sql)
-- Introduces: languages, translation_namespaces, translations, schema_migrations
-- Consumers: website/lib/i18n/getDictionary.js, app/api/translations/[lang]/route.js
-- Engine: MySQL 8+
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS schema_migrations (
  version       VARCHAR(64) NOT NULL PRIMARY KEY,
  description   VARCHAR(255) NOT NULL,
  applied_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- languages: which locales the app serves, matches Next.js [lang] segment
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS languages (
  code          VARCHAR(10) NOT NULL PRIMARY KEY,      -- BCP-47-ish: en, id, zh-CN, ko, vi, ru, es, pt
  name          VARCHAR(64) NOT NULL,                  -- English display name
  native_name   VARCHAR(64) NOT NULL,                  -- name in its own language
  direction     ENUM('ltr','rtl') NOT NULL DEFAULT 'ltr',
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  is_default    BOOLEAN NOT NULL DEFAULT FALSE,
  sort_order    INT NOT NULL DEFAULT 100,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Only one default language
CREATE UNIQUE INDEX uq_languages_single_default
  ON languages ((CASE WHEN is_default THEN 1 ELSE NULL END));

-- ---------------------------------------------------------------------------
-- translation_namespaces: groups keys by feature/page (verify-wallet, nav, ...)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS translation_namespaces (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  slug          VARCHAR(64) NOT NULL UNIQUE,           -- e.g. 'verify-wallet', 'common'
  description   VARCHAR(255) NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- translations: the actual strings, versioned per row for cache-busting
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS translations (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  namespace_id    INT NOT NULL,
  lang_code       VARCHAR(10) NOT NULL,
  translation_key VARCHAR(128) NOT NULL,               -- e.g. 'verify_wallet.cta'
  value           TEXT NOT NULL,
  content_hash    CHAR(64) NOT NULL,                   -- sha256(value), used to detect real changes
  version         INT NOT NULL DEFAULT 1,
  updated_by      VARCHAR(64) NULL,                    -- e.g. 'sync_translations.py'
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_translations_namespace
    FOREIGN KEY (namespace_id) REFERENCES translation_namespaces(id)
    ON DELETE CASCADE,
  CONSTRAINT fk_translations_lang
    FOREIGN KEY (lang_code) REFERENCES languages(code)
    ON DELETE CASCADE,
  CONSTRAINT uq_translations_unique_key
    UNIQUE (namespace_id, lang_code, translation_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX idx_translations_lookup
  ON translations (namespace_id, lang_code);

-- ---------------------------------------------------------------------------
-- Seed: active languages (Pi Network's largest community locales)
-- ---------------------------------------------------------------------------
INSERT INTO languages (code, name, native_name, direction, is_active, is_default, sort_order) VALUES
  ('en',    'English',              'English',          'ltr', TRUE, TRUE,  1),
  ('id',    'Indonesian',           'Bahasa Indonesia',  'ltr', TRUE, FALSE, 2),
  ('zh-CN', 'Chinese (Simplified)', '简体中文',           'ltr', TRUE, FALSE, 3),
  ('ko',    'Korean',               '한국어',             'ltr', TRUE, FALSE, 4),
  ('vi',    'Vietnamese',           'Tiếng Việt',        'ltr', TRUE, FALSE, 5),
  ('ru',    'Russian',              'Русский',           'ltr', TRUE, FALSE, 6),
  ('es',    'Spanish',              'Español',           'ltr', TRUE, FALSE, 7),
  ('pt',    'Portuguese',           'Português',         'ltr', TRUE, FALSE, 8)
ON DUPLICATE KEY UPDATE
  name = VALUES(name), native_name = VALUES(native_name), is_active = VALUES(is_active);

-- ---------------------------------------------------------------------------
-- Seed: namespaces
-- ---------------------------------------------------------------------------
INSERT INTO translation_namespaces (slug, description) VALUES
  ('verify-wallet', 'Pi wallet verification page (@pibrowser/verify-wallet)'),
  ('common',        'Shared strings used across the pibrowser app shell')
ON DUPLICATE KEY UPDATE description = VALUES(description);

-- ---------------------------------------------------------------------------
-- Seed: verify-wallet strings, all 8 languages
-- ---------------------------------------------------------------------------
INSERT INTO translations (namespace_id, lang_code, translation_key, value, content_hash, version, updated_by)
SELECT n.id, v.lang_code, v.translation_key, v.value, SHA2(v.value, 256), 1, 'explorepi_i18n_schema.sql'
FROM translation_namespaces n
JOIN (
  SELECT 'en'    AS lang_code, 'verify_wallet.cta'      AS translation_key, 'Verify Wallet' AS value UNION ALL
  SELECT 'en',    'verify_wallet.memo',                 'Verify Wallet' UNION ALL
  SELECT 'en',    'verify_wallet.error_generic',        'Something went wrong. Please try again.' UNION ALL
  SELECT 'en',    'verify_wallet.auth_failed',           'Pi authentication failed.' UNION ALL

  SELECT 'id',    'verify_wallet.cta',                  'Verifikasi Dompet' UNION ALL
  SELECT 'id',    'verify_wallet.memo',                 'Verifikasi Dompet' UNION ALL
  SELECT 'id',    'verify_wallet.error_generic',        'Terjadi kesalahan. Silakan coba lagi.' UNION ALL
  SELECT 'id',    'verify_wallet.auth_failed',           'Autentikasi Pi gagal.' UNION ALL

  SELECT 'zh-CN', 'verify_wallet.cta',                  '验证钱包' UNION ALL
  SELECT 'zh-CN', 'verify_wallet.memo',                 '验证钱包' UNION ALL
  SELECT 'zh-CN', 'verify_wallet.error_generic',        '出现错误，请重试。' UNION ALL
  SELECT 'zh-CN', 'verify_wallet.auth_failed',           'Pi 身份验证失败。' UNION ALL

  SELECT 'ko',    'verify_wallet.cta',                  '지갑 인증' UNION ALL
  SELECT 'ko',    'verify_wallet.memo',                 '지갑 인증' UNION ALL
  SELECT 'ko',    'verify_wallet.error_generic',        '문제가 발생했습니다. 다시 시도해 주세요.' UNION ALL
  SELECT 'ko',    'verify_wallet.auth_failed',           'Pi 인증에 실패했습니다.' UNION ALL

  SELECT 'vi',    'verify_wallet.cta',                  'Xác Minh Ví' UNION ALL
  SELECT 'vi',    'verify_wallet.memo',                 'Xác Minh Ví' UNION ALL
  SELECT 'vi',    'verify_wallet.error_generic',        'Đã xảy ra lỗi. Vui lòng thử lại.' UNION ALL
  SELECT 'vi',    'verify_wallet.auth_failed',           'Xác thực Pi không thành công.' UNION ALL

  SELECT 'ru',    'verify_wallet.cta',                  'Подтвердить кошелёк' UNION ALL
  SELECT 'ru',    'verify_wallet.memo',                 'Подтвердить кошелёк' UNION ALL
  SELECT 'ru',    'verify_wallet.error_generic',        'Что-то пошло не так. Попробуйте снова.' UNION ALL
  SELECT 'ru',    'verify_wallet.auth_failed',           'Не удалось выполнить аутентификацию Pi.' UNION ALL

  SELECT 'es',    'verify_wallet.cta',                  'Verificar Billetera' UNION ALL
  SELECT 'es',    'verify_wallet.memo',                 'Verificar Billetera' UNION ALL
  SELECT 'es',    'verify_wallet.error_generic',        'Algo salió mal. Inténtalo de nuevo.' UNION ALL
  SELECT 'es',    'verify_wallet.auth_failed',           'Falló la autenticación de Pi.' UNION ALL

  SELECT 'pt',    'verify_wallet.cta',                  'Verificar Carteira' UNION ALL
  SELECT 'pt',    'verify_wallet.memo',                 'Verificar Carteira' UNION ALL
  SELECT 'pt',    'verify_wallet.error_generic',        'Algo deu errado. Tente novamente.' UNION ALL
  SELECT 'pt',    'verify_wallet.auth_failed',           'Falha na autenticação do Pi.'
) v ON n.slug = 'verify-wallet'
ON DUPLICATE KEY UPDATE
  value = VALUES(value),
  content_hash = VALUES(content_hash),
  version = IF(translations.content_hash = VALUES(content_hash), translations.version, translations.version + 1),
  updated_by = VALUES(updated_by);

INSERT INTO schema_migrations (version, description) VALUES
  ('20260911_i18n_v1', 'Create languages/translation_namespaces/translations + seed verify-wallet strings')
ON DUPLICATE KEY UPDATE description = VALUES(description);
