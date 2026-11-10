// kyc/db.js
// Pool PostgreSQL + helper query() yang dipakai Oauth/Auth.js dan Oauth/kyc.js
// (`import { query } from '../db.js'`). File ini sebelumnya tidak ada sama
// sekali di repo — lihat Document.md, tinjauan Fase 1 (10 Nov 2026).
//
// Target skema: schema.sql di folder ini (accounts, pq_keys, account_secrets,
// sessions, audit_logs, ...). Connection string diambil dari DATABASE_URL,
// sesuai yang sudah disiapkan di docker.yml untuk service "api":
//   DATABASE_URL: postgresql://explorepi:${POSTGRES_PASSWORD}@db:5432/explorepi
//
// pip install -> tidak relevan di sini; dependency Node: `pg`
//   npm install pg

import pg from 'pg';

const { Pool } = pg;

if (!process.env.DATABASE_URL) {
  throw new Error(
    "DATABASE_URL belum diset. Isi .env dengan connection string Postgres " +
      '(lihat docker.yml, service "api", atau Oauth/Readme.md).'
  );
}

// Simpan pool di globalThis supaya hot-reload dev (next dev / --watch) tidak
// bikin pool baru tiap kali modul ini di-reload dan bikin koneksi bocor.
export const pool =
  globalThis.__explorepiKycDbPool ||
  new Pool({
    connectionString: process.env.DATABASE_URL,
    max: Number(process.env.PGPOOL_MAX || 10),
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
  });

if (process.env.NODE_ENV !== 'production') {
  globalThis.__explorepiKycDbPool = pool;
}

// Client idle di pool bisa melempar event 'error' kapan saja (mis. koneksi ke
// Postgres putus di belakang layar). Kalau event ini tidak ditangani, Node
// akan meng-crash SELURUH proses, bukan cuma query yang sedang jalan — jadi
// listener ini wajib ada, bukan sekadar logging tambahan.
pool.on('error', (err) => {
  console.error('[kyc/db] idle client error:', err.message);
});

// Selaras dengan sql.conf: log_min_duration_statement = 500ms di sisi
// Postgres. Di sisi aplikasi kita tandai juga supaya kelihatan query mana
// yang lambat tanpa harus buka log Postgres.
const SLOW_QUERY_MS = Number(process.env.PG_SLOW_QUERY_MS || 500);

/**
 * Jalankan satu query lewat pool.
 * Dipakai sebagai: const { rows } = await query('SELECT ... WHERE id = $1', [id]);
 *
 * @param {string} text
 * @param {any[]} [params]
 * @returns {Promise<import('pg').QueryResult>}
 */
export async function query(text, params) {
  const start = Date.now();
  try {
    const result = await pool.query(text, params);
    const durationMs = Date.now() - start;
    if (durationMs > SLOW_QUERY_MS) {
      console.warn(`[kyc/db] query lambat (${durationMs}ms): ${text.slice(0, 120)}`);
    }
    return result;
  } catch (err) {
    console.error(`[kyc/db] query gagal: ${text.slice(0, 120)} ->`, err.message);
    throw err;
  }
}

/**
 * Jalankan beberapa query dalam satu transaksi (BEGIN/COMMIT/ROLLBACK).
 *
 * Catatan: Auth.js saat ini membuat account + account_profiles +
 * oauth_accounts lewat tiga panggilan query() terpisah (tidak transaksional).
 * Kalau nanti itu perlu dibikin atomik, pindah ke pola ini:
 *
 *   await withTransaction(async (client) => {
 *     const { rows } = await client.query('INSERT INTO accounts ...');
 *     await client.query('INSERT INTO account_profiles ...', [rows[0].id]);
 *   });
 *
 * @template T
 * @param {(client: import('pg').PoolClient) => Promise<T>} fn
 * @returns {Promise<T>}
 */
export async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

/**
 * Tutup pool dengan rapi. Panggil ini saat shutdown proses (SIGTERM/SIGINT),
 * BUKAN di tiap request — pool dipakai ulang selama proses hidup.
 */
export async function closePool() {
  await pool.end();
}
