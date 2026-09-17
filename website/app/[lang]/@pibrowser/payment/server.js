'use strict';

// =============================================================================
// ExplorePi API — read-only REST layer over database.sql
// (blocks, transactions, operations, payments, accounts, assets, network_stats)
// =============================================================================

require('dotenv').config();

const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');

const PORT = Number(process.env.PORT) || 4000;
const DATABASE_URL = process.env.DATABASE_URL;

if (!DATABASE_URL) {
  console.error('Missing DATABASE_URL in environment. Copy .env.example to .env and fill it in.');
  process.exit(1);
}

const pool = new Pool({ connectionString: DATABASE_URL, max: 10 });

const app = express();
app.use(cors());
app.use(express.json());

// Small helper so route handlers can stay flat and errors go to next()
const route = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

const parseLimit = (value, { def = 20, max = 200 } = {}) => {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return def;
  return Math.min(Math.trunc(n), max);
};

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------
app.get('/health', route(async (req, res) => {
  await pool.query('SELECT 1');
  res.json({ status: 'ok' });
}));

// ---------------------------------------------------------------------------
// Network stats — latest snapshot written by the crawler
// ---------------------------------------------------------------------------
app.get('/stats', route(async (req, res) => {
  const { rows } = await pool.query(
    'SELECT * FROM network_stats ORDER BY recorded_at DESC LIMIT 1'
  );
  res.json(rows[0] ?? null);
}));

// ---------------------------------------------------------------------------
// Blocks (ledgers)
// ---------------------------------------------------------------------------
app.get('/blocks', route(async (req, res) => {
  const limit = parseLimit(req.query.limit);
  const { rows } = await pool.query(
    'SELECT * FROM blocks ORDER BY sequence DESC LIMIT $1',
    [limit]
  );
  res.json(rows);
}));

app.get('/blocks/:sequence', route(async (req, res) => {
  const { rows } = await pool.query(
    'SELECT * FROM blocks WHERE sequence = $1',
    [req.params.sequence]
  );
  if (!rows[0]) return res.status(404).json({ error: 'block not found' });
  res.json(rows[0]);
}));

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------
app.get('/transactions/:hash', route(async (req, res) => {
  const { rows } = await pool.query(
    'SELECT * FROM transactions WHERE hash = $1',
    [req.params.hash]
  );
  if (!rows[0]) return res.status(404).json({ error: 'transaction not found' });
  res.json(rows[0]);
}));

app.get('/transactions/:hash/operations', route(async (req, res) => {
  const { rows } = await pool.query(
    'SELECT * FROM operations WHERE tx_hash = $1 ORDER BY op_index ASC',
    [req.params.hash]
  );
  res.json(rows);
}));

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------
app.get('/accounts/:address', route(async (req, res) => {
  const { rows } = await pool.query(
    'SELECT * FROM accounts WHERE address = $1',
    [req.params.address]
  );
  if (!rows[0]) return res.status(404).json({ error: 'account not found' });
  res.json(rows[0]);
}));

app.get('/accounts/:address/payments', route(async (req, res) => {
  const limit = parseLimit(req.query.limit);
  const { rows } = await pool.query(
    `SELECT * FROM payments
     WHERE from_account = $1 OR to_account = $1
     ORDER BY created_at DESC
     LIMIT $2`,
    [req.params.address, limit]
  );
  res.json(rows.map(toHorizonShape));
}));

// ---------------------------------------------------------------------------
// Payments — shaped to match what explorer/payment.jsx already reads off a
// live Horizon record: from, to, amount, created_at, type_i.
// ---------------------------------------------------------------------------
app.get('/payments', route(async (req, res) => {
  const limit = parseLimit(req.query.limit);
  const { rows } = await pool.query(
    'SELECT * FROM payments ORDER BY created_at DESC LIMIT $1',
    [limit]
  );
  res.json(rows.map(toHorizonShape));
}));

function toHorizonShape(row) {
  return {
    id: row.id,
    tx_hash: row.tx_hash,
    type_i: 1,
    from: row.from_account,
    to: row.to_account,
    amount: row.amount,
    asset_type: row.asset_type,
    asset_code: row.asset_code,
    asset_issuer: row.asset_issuer,
    created_at: row.created_at,
  };
}

// ---------------------------------------------------------------------------
// 404 + error handling
// ---------------------------------------------------------------------------
app.use((req, res) => res.status(404).json({ error: 'not found' }));

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'internal server error' });
});

app.listen(PORT, () => {
  console.log(`ExplorePi API listening on :${PORT}`);
});

module.exports = app;
