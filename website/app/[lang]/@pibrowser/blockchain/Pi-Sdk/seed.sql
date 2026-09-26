-- =============================================================================
-- @pibrowser/blockchain — seed data
-- Chains + full 8-locale translation set for the 'blockchain' namespace
-- =============================================================================

INSERT INTO languages (code, name_native, is_active) VALUES
  ('en',    'English',    1),
  ('id',    'Bahasa Indonesia', 1),
  ('zh-CN', '简体中文',    1),
  ('ko',    '한국어',      1),
  ('vi',    'Tiếng Việt', 1),
  ('ru',    'Русский',    1),
  ('es',    'Español',    1),
  ('pt',    'Português',  1)
ON DUPLICATE KEY UPDATE name_native = VALUES(name_native);

INSERT INTO blockchain_chains (chain_id, kind, label, network, rpc_url, is_enabled, sort_order) VALUES
  ('pi',       'stellar-soroban', 'Pi Network', 'mainnet',      'https://api.mainnet.minepi.com',   1, 1),
  ('solana',   'solana',          'Solana',     'mainnet-beta', 'https://api.mainnet-beta.solana.com', 1, 2),
  ('ethereum', 'evm',             'Ethereum',   'mainnet',      'https://cloudflare-eth.com',       1, 3)
ON DUPLICATE KEY UPDATE label = VALUES(label), network = VALUES(network);

-- Translation keys x 8 locales. content_hash = SHA2(value, 256), matches
-- sync_translations.py's content-hash versioning scheme.
INSERT INTO translations (namespace, lang_code, key_path, value, content_hash) VALUES
-- English
('blockchain','en','nav.title','Blockchain',SHA2('Blockchain',256)),
('blockchain','en','chain.select','Select chain',SHA2('Select chain',256)),
('blockchain','en','ledger.latest','Latest ledger',SHA2('Latest ledger',256)),
('blockchain','en','block.latest','Latest block',SHA2('Latest block',256)),
('blockchain','en','contracts.recent','Recent contract events',SHA2('Recent contract events',256)),
('blockchain','en','status.unavailable','Data temporarily unavailable',SHA2('Data temporarily unavailable',256)),
-- Indonesian
('blockchain','id','nav.title','Blockchain',SHA2('Blockchain',256)),
('blockchain','id','chain.select','Pilih jaringan',SHA2('Pilih jaringan',256)),
('blockchain','id','ledger.latest','Ledger terbaru',SHA2('Ledger terbaru',256)),
('blockchain','id','block.latest','Blok terbaru',SHA2('Blok terbaru',256)),
('blockchain','id','contracts.recent','Kejadian kontrak terbaru',SHA2('Kejadian kontrak terbaru',256)),
('blockchain','id','status.unavailable','Data sementara tidak tersedia',SHA2('Data sementara tidak tersedia',256)),
-- Chinese (Simplified)
('blockchain','zh-CN','nav.title','区块链',SHA2('区块链',256)),
('blockchain','zh-CN','chain.select','选择链',SHA2('选择链',256)),
('blockchain','zh-CN','ledger.latest','最新账本',SHA2('最新账本',256)),
('blockchain','zh-CN','block.latest','最新区块',SHA2('最新区块',256)),
('blockchain','zh-CN','contracts.recent','最近的合约事件',SHA2('最近的合约事件',256)),
('blockchain','zh-CN','status.unavailable','数据暂时不可用',SHA2('数据暂时不可用',256)),
-- Korean
('blockchain','ko','nav.title','블록체인',SHA2('블록체인',256)),
('blockchain','ko','chain.select','체인 선택',SHA2('체인 선택',256)),
('blockchain','ko','ledger.latest','최신 원장',SHA2('최신 원장',256)),
('blockchain','ko','block.latest','최신 블록',SHA2('최신 블록',256)),
('blockchain','ko','contracts.recent','최근 컨트랙트 이벤트',SHA2('최근 컨트랙트 이벤트',256)),
('blockchain','ko','status.unavailable','데이터를 일시적으로 사용할 수 없습니다',SHA2('데이터를 일시적으로 사용할 수 없습니다',256)),
-- Vietnamese
('blockchain','vi','nav.title','Blockchain',SHA2('Blockchain',256)),
('blockchain','vi','chain.select','Chọn chuỗi',SHA2('Chọn chuỗi',256)),
('blockchain','vi','ledger.latest','Sổ cái mới nhất',SHA2('Sổ cái mới nhất',256)),
('blockchain','vi','block.latest','Khối mới nhất',SHA2('Khối mới nhất',256)),
('blockchain','vi','contracts.recent','Sự kiện hợp đồng gần đây',SHA2('Sự kiện hợp đồng gần đây',256)),
('blockchain','vi','status.unavailable','Dữ liệu tạm thời không khả dụng',SHA2('Dữ liệu tạm thời không khả dụng',256)),
-- Russian
('blockchain','ru','nav.title','Блокчейн',SHA2('Блокчейн',256)),
('blockchain','ru','chain.select','Выберите сеть',SHA2('Выберите сеть',256)),
('blockchain','ru','ledger.latest','Последний леджер',SHA2('Последний леджер',256)),
('blockchain','ru','block.latest','Последний блок',SHA2('Последний блок',256)),
('blockchain','ru','contracts.recent','Недавние события контрактов',SHA2('Недавние события контрактов',256)),
('blockchain','ru','status.unavailable','Данные временно недоступны',SHA2('Данные временно недоступны',256)),
-- Spanish
('blockchain','es','nav.title','Blockchain',SHA2('Blockchain',256)),
('blockchain','es','chain.select','Seleccionar red',SHA2('Seleccionar red',256)),
('blockchain','es','ledger.latest','Último ledger',SHA2('Último ledger',256)),
('blockchain','es','block.latest','Último bloque',SHA2('Último bloque',256)),
('blockchain','es','contracts.recent','Eventos de contrato recientes',SHA2('Eventos de contrato recientes',256)),
('blockchain','es','status.unavailable','Datos no disponibles temporalmente',SHA2('Datos no disponibles temporalmente',256)),
-- Portuguese
('blockchain','pt','nav.title','Blockchain',SHA2('Blockchain',256)),
('blockchain','pt','chain.select','Selecionar rede',SHA2('Selecionar rede',256)),
('blockchain','pt','ledger.latest','Último ledger',SHA2('Último ledger',256)),
('blockchain','pt','block.latest','Último bloco',SHA2('Último bloco',256)),
('blockchain','pt','contracts.recent','Eventos recentes de contrato',SHA2('Eventos recentes de contrato',256)),
('blockchain','pt','status.unavailable','Dados temporariamente indisponíveis',SHA2('Dados temporariamente indisponíveis',256))
ON DUPLICATE KEY UPDATE value = VALUES(value), content_hash = VALUES(content_hash);
