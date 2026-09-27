// lib/db.js
// Shared PostgreSQL connection pool for the @pibrowser/payment module.
import pg from 'pg';

const { Pool } = pg;

export const pool = global._piPaymentPool || new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
  idleTimeoutMillis: 30000,
});

if (process.env.NODE_ENV !== 'production') {
  global._piPaymentPool = pool;
}
