/**
 * @pibrowser/blockchain/database/db.js
 * MySQL-backed data layer with JSON-file fallback, matching the pattern used
 * by lib/i18n/db.js in the rest of ExplorePi.
 */

import mysql from 'mysql2/promise';
import fs from 'node:fs/promises';
import path from 'node:path';

let pool = null;

function getPool() {
  if (!pool) {
    pool = mysql.createPool({
      host: process.env.MYSQL_HOST || 'localhost',
      port: Number(process.env.MYSQL_PORT || 3306),
      user: process.env.MYSQL_USER || 'explorepi',
      password: process.env.MYSQL_PASSWORD || '',
      database: process.env.MYSQL_DATABASE || 'explorepi',
      waitForConnections: true,
      connectionLimit: 10,
      namedPlaceholders: true,
    });
  }
  return pool;
}

const FALLBACK_DIR = path.join(process.cwd(), 'app/[lang]/@pibrowser/blockchain/database/locales');

async function loadFallbackDictionary(lang) {
  try {
    const file = path.join(FALLBACK_DIR, `${lang}.json`);
    const raw = await fs.readFile(file, 'utf-8');
    return JSON.parse(raw);
  } catch {
    if (lang !== 'en') return loadFallbackDictionary('en');
    return {};
  }
}

/**
 * Returns a flat { 'key.path': value } dictionary for the blockchain namespace.
 * Tries MySQL first; falls back to bundled JSON if the DB is unreachable.
 */
export async function getBlockchainDictionary(lang) {
  try {
    const [rows] = await getPool().query(
      `SELECT key_path, value FROM translations WHERE namespace = :ns AND lang_code = :lang`,
      { ns: 'blockchain', lang }
    );
    if (rows.length === 0) return loadFallbackDictionary(lang);
    return Object.fromEntries(rows.map((r) => [r.key_path, r.value]));
  } catch (err) {
    console.error('[blockchain/db] MySQL unavailable, using JSON fallback', err.message);
    return loadFallbackDictionary(lang);
  }
}

export async function getEnabledChains() {
  try {
    const [rows] = await getPool().query(
      `SELECT chain_id, kind, label, network, rpc_url FROM blockchain_chains
       WHERE is_enabled = 1 ORDER BY sort_order ASC`
    );
    return rows;
  } catch (err) {
    console.error('[blockchain/db] MySQL unavailable, using static chain list', err.message);
    return [
      { chain_id: 'pi', kind: 'stellar-soroban', label: 'Pi Network', network: 'mainnet' },
      { chain_id: 'solana', kind: 'solana', label: 'Solana', network: 'mainnet-beta' },
      { chain_id: 'ethereum', kind: 'evm', label: 'Ethereum', network: 'mainnet' },
    ];
  }
}

export async function cacheSnapshot(chainId, payload, ttlSeconds = 15) {
  try {
    await getPool().query(
      `INSERT INTO blockchain_snapshot_cache (chain_id, payload_json, expires_at)
       VALUES (:chainId, :payload, DATE_ADD(NOW(), INTERVAL :ttl SECOND))
       ON DUPLICATE KEY UPDATE payload_json = VALUES(payload_json), fetched_at = NOW(), expires_at = VALUES(expires_at)`,
      { chainId, payload: JSON.stringify(payload), ttl: ttlSeconds }
    );
  } catch (err) {
    console.error('[blockchain/db] cacheSnapshot failed (non-fatal)', err.message);
  }
}

export async function getCachedSnapshot(chainId) {
  try {
    const [rows] = await getPool().query(
      `SELECT payload_json FROM blockchain_snapshot_cache
       WHERE chain_id = :chainId AND expires_at > NOW() LIMIT 1`,
      { chainId }
    );
    return rows[0] ? JSON.parse(rows[0].payload_json) : null;
  } catch {
    return null;
  }
}
