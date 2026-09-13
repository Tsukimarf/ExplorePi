'use strict';

// =============================================================================
// ExplorePi – Pi Blockchain Crawler  (crawler/index.js)
// Tsukimarf/ExplorePi
// =============================================================================

const { Pool }         = require('pg');
const fetch            = require('node-fetch');
const { EventEmitter } = require('events');

// ---------------------------------------------------------------------------
// Config  (values come from environment / config.json)
// ---------------------------------------------------------------------------
const CONFIG = {
  HORIZON_URL:    process.env.HORIZON_URL   || 'https://api.mainnet.minepi.com',
  DB_URL:         process.env.DATABASE_URL,
  POLL_INTERVAL:  Number(process.env.POLL_INTERVAL)  || 6_000,   // ms between polls
  BATCH_SIZE:     Number(process.env.BATCH_SIZE)     || 200,     // ledgers per chunk
  MAX_RETRIES:    Number(process.env.MAX_RETRIES)    || 5,
  RETRY_DELAY:    Number(process.env.RETRY_DELAY)    || 2_000,
  LOG_LEVEL:      process.env.LOG_LEVEL     || 'info',
  NETWORK:        process.env.NETWORK       || 'mainnet',
};

// ---------------------------------------------------------------------------
// Logger
// ---------------------------------------------------------------------------
const LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };
const log = {
  _write(level, msg, meta) {
    if (LOG_LEVELS[level] < LOG_LEVELS[CONFIG.LOG_LEVEL]) return;
    const line = JSON.stringify({ ts: new Date().toISOString(), level, msg, ...meta });
    (level === 'error' ? console.error : console.log)(line);
  },
  debug: (msg, m = {}) => log._write('debug', msg, m),
  info:  (msg, m = {}) => log._write('info',  msg, m),
  warn:  (msg, m = {}) => log._write('warn',  msg, m),
  error: (msg, m = {}) => log._write('error', msg, m),
};

// ---------------------------------------------------------------------------
// Database pool
// ---------------------------------------------------------------------------
const db = new Pool({ connectionString: CONFIG.DB_URL, max: 10 });

async function dbQuery(sql, params = []) {
  const client = await db.connect();
  try {
    return await client.query(sql, params);
  } finally {
    client.release();
  }
}

// ---------------------------------------------------------------------------
// Horizon HTTP helpers
// ---------------------------------------------------------------------------
async function horizonGet(path, retries = CONFIG.MAX_RETRIES) {
  const url = `${CONFIG.HORIZON_URL}${path}`;
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const res = await fetch(url, { headers: { Accept: 'application/json' } });
      if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
      return await res.json();
    } catch (err) {
      if (attempt === retries) throw err;
      log.warn('Horizon request failed, retrying…', { attempt, url, error: err.message });
      await sleep(CONFIG.RETRY_DELAY * attempt);
    }
  }
}

async function horizonGetAll(path) {
  const results = [];
  let next = path;
  while (next) {
    const page = await horizonGet(next);
    results.push(...(page._embedded?.records ?? []));
    next = page._links?.next?.href
      ? new URL(page._links.next.href).pathname + new URL(page._links.next.href).search
      : null;
  }
  return results;
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// State helpers
// ---------------------------------------------------------------------------
async function getState(key) {
  const { rows } = await dbQuery(
    'SELECT value FROM crawler_state WHERE key = $1', [key]
  );
  return rows[0]?.value ?? null;
}

async function setState(key, value) {
  await dbQuery(
    `INSERT INTO crawler_state (key, value, updated_at)
     VALUES ($1, $2, NOW())
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()`,
    [key, String(value)]
  );
}

// ---------------------------------------------------------------------------
// Block (ledger) ingestion
// ---------------------------------------------------------------------------
async function ingestLedger(ledger) {
  const client = await db.connect();
  try {
    await client.query('BEGIN');

    // Upsert block
    await client.query(
      `INSERT INTO blocks
         (sequence, hash, prev_hash, closed_at, tx_count, op_count,
          total_fees, base_fee, base_reserve, max_tx_set_size, protocol_version)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       ON CONFLICT (sequence) DO UPDATE SET
         tx_count = EXCLUDED.tx_count,
         op_count = EXCLUDED.op_count`,
      [
        ledger.sequence,
        ledger.hash,
        ledger.prev_hash,
        ledger.closed_at,
        ledger.transaction_count,
        ledger.operation_count,
        ledger.fee_pool,
        ledger.base_fee_in_stroops,
        ledger.base_reserve_in_stroops / 10_000_000,
        ledger.max_tx_set_size,
        ledger.protocol_version,
      ]
    );

    await client.query('COMMIT');
    log.debug('Block ingested', { sequence: ledger.sequence });
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// ---------------------------------------------------------------------------
// Transaction ingestion
// ---------------------------------------------------------------------------
async function ingestTransaction(tx) {
  await dbQuery(
    `INSERT INTO transactions
       (hash, block_sequence, source_account, fee, fee_account, op_count,
        memo_type, memo, status, result_code, envelope_xdr, result_xdr, ledger_closed_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
     ON CONFLICT (hash) DO NOTHING`,
    [
      tx.hash,
      tx.ledger,
      tx.source_account,
      tx.fee_charged,
      tx.fee_account,
      tx.operation_count,
      tx.memo_type === 'none' ? null : tx.memo_type,
      tx.memo || null,
      tx.successful ? 'success' : 'failed',
      tx.result_code ?? null,
      tx.envelope_xdr,
      tx.result_xdr,
      tx.created_at,
    ]
  );
}

// ---------------------------------------------------------------------------
// Operation ingestion
// ---------------------------------------------------------------------------
async function ingestOperation(op) {
  const details = buildOpDetails(op);

  const { rows } = await dbQuery(
    `INSERT INTO operations
       (tx_hash, block_sequence, op_index, type, source_account, details, created_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7)
     ON CONFLICT (tx_hash, op_index) DO NOTHING
     RETURNING id`,
    [
      op.transaction_hash,
      op.ledger,
      op.paging_token.split('-')[1] ?? 0,
      op.type,
      op.source_account ?? null,
      JSON.stringify(details),
      op.created_at,
    ]
  );

  // Denormalize payment-type ops
  if (['payment', 'create_account', 'path_payment_strict_receive', 'path_payment_strict_send'].includes(op.type)) {
    await ingestPayment(op, rows[0]?.id);
  }
}

function buildOpDetails(op) {
  const base = { type: op.type };
  switch (op.type) {
    case 'payment':
      return { ...base, from: op.from, to: op.to, amount: op.amount, asset: { type: op.asset_type, code: op.asset_code, issuer: op.asset_issuer } };
    case 'create_account':
      return { ...base, funder: op.funder, account: op.account, starting_balance: op.starting_balance };
    case 'change_trust':
      return { ...base, trustee: op.trustee, trustor: op.trustor, asset: { type: op.asset_type, code: op.asset_code, issuer: op.asset_issuer }, limit: op.limit };
    case 'manage_sell_offer':
    case 'manage_buy_offer':
      return { ...base, offer_id: op.offer_id, amount: op.amount, price: op.price };
    case 'set_options':
      return { ...base, signer_key: op.signer_key, signer_weight: op.signer_weight, home_domain: op.home_domain, flags: { set: op.set_flags_s, clear: op.clear_flags_s } };
    default:
      return base;
  }
}

async function ingestPayment(op, opId) {
  if (!opId) return;
  const from = op.from ?? op.funder ?? op.source_account;
  const to   = op.to   ?? op.account;
  if (!from || !to) return;

  await dbQuery(
    `INSERT INTO payments
       (op_id, tx_hash, block_sequence, from_account, to_account,
        asset_type, asset_code, asset_issuer, amount, created_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
     ON CONFLICT DO NOTHING`,
    [
      opId,
      op.transaction_hash,
      op.ledger,
      from,
      to,
      op.asset_type ?? 'native',
      op.asset_code ?? null,
      op.asset_issuer ?? null,
      op.amount ?? op.starting_balance ?? '0',
      op.created_at,
    ]
  );
}

// ---------------------------------------------------------------------------
// Ledger range sync
// ---------------------------------------------------------------------------
async function syncLedgerRange(fromSeq, toSeq) {
  log.info('Syncing ledger range', { from: fromSeq, to: toSeq });

  const ledgers = await horizonGet(
    `/ledgers?cursor=${fromSeq - 1}&order=asc&limit=${Math.min(toSeq - fromSeq + 1, 200)}`
  );

  for (const ledger of ledgers._embedded?.records ?? []) {
    try {
      await ingestLedger(ledger);

      // Fetch and ingest all transactions for this ledger
      const txs = await horizonGetAll(`/ledgers/${ledger.sequence}/transactions?limit=200`);
      for (const tx of txs) {
        await ingestTransaction(tx);
        const ops = await horizonGetAll(`/transactions/${tx.hash}/operations?limit=200`);
        for (const op of ops) {
          await ingestOperation(op);
        }
      }

      await setState('last_synced_ledger', ledger.sequence);
    } catch (err) {
      log.error('Failed to ingest ledger', { sequence: ledger.sequence, error: err.message });
      throw err;
    }
  }
}

// ---------------------------------------------------------------------------
// Network stats snapshot
// ---------------------------------------------------------------------------
async function snapshotNetworkStats(latestLedger) {
  const [accounts, txs, ops, payments] = await Promise.all([
    dbQuery('SELECT COUNT(*) FROM accounts'),
    dbQuery('SELECT COUNT(*) FROM transactions'),
    dbQuery('SELECT COUNT(*) FROM operations'),
    dbQuery('SELECT COUNT(*) FROM payments'),
  ]);

  const tps1h = await dbQuery(
    `SELECT COUNT(*)::NUMERIC / 3600 AS tps FROM transactions
     WHERE ledger_closed_at >= NOW() - INTERVAL '1 hour'`
  );

  const fees24h = await dbQuery(
    `SELECT COALESCE(SUM(fee), 0) AS fees FROM transactions
     WHERE ledger_closed_at >= NOW() - INTERVAL '24 hours'`
  );

  await dbQuery(
    `INSERT INTO network_stats
       (total_accounts, total_txs, total_ops, total_payments, latest_ledger, tps_1h, fees_24h)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [
      accounts.rows[0].count,
      txs.rows[0].count,
      ops.rows[0].count,
      payments.rows[0].count,
      latestLedger,
      tps1h.rows[0].tps,
      fees24h.rows[0].fees,
    ]
  );

  log.info('Network stats snapshot saved', { latestLedger });
}

// ---------------------------------------------------------------------------
// Main crawl loop
// ---------------------------------------------------------------------------
class Crawler extends EventEmitter {
  constructor() {
    super();
    this.running  = false;
    this.syncedAt = null;
  }

  async start() {
    this.running = true;
    log.info('Crawler starting', { network: CONFIG.NETWORK, horizon: CONFIG.HORIZON_URL });

    while (this.running) {
      try {
        await this._tick();
      } catch (err) {
        log.error('Crawler tick failed', { error: err.message, stack: err.stack });
        this.emit('error', err);
      }
      await sleep(CONFIG.POLL_INTERVAL);
    }
  }

  stop() {
    log.info('Crawler stopping…');
    this.running = false;
  }

  async _tick() {
    // Latest ledger from Horizon
    const root   = await horizonGet('/');
    const latest = Number(root.core_latest_ledger ?? root.history_latest_ledger);
    const cursor = Number(await getState('last_synced_ledger') ?? 0);

    if (cursor >= latest) {
      log.debug('Up to date', { cursor, latest });
      return;
    }

    const batchTo = Math.min(cursor + CONFIG.BATCH_SIZE, latest);
    await syncLedgerRange(cursor + 1, batchTo);

    // Snapshot stats every ~50 ledgers
    if (batchTo % 50 < CONFIG.BATCH_SIZE) {
      await snapshotNetworkStats(batchTo).catch(err =>
        log.warn('Stats snapshot failed', { error: err.message })
      );
    }

    this.syncedAt = new Date();
    this.emit('synced', { from: cursor + 1, to: batchTo });
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
(async () => {
  const crawler = new Crawler();

  process.on('SIGTERM', () => { crawler.stop(); db.end(); });
  process.on('SIGINT',  () => { crawler.stop(); db.end(); });

  crawler.on('error', err => {
    log.error('Unhandled crawler error', { error: err.message });
  });

  crawler.on('synced', ({ from, to }) => {
    log.info('Batch synced', { from, to, blocks: to - from + 1 });
  });

  await crawler.start();
})();