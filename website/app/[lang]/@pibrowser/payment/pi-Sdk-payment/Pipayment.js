// lib/pi/piPayment.js
// Server-side wrapper around pi-backend for the Pi Platform payments API.
// Called only from route handlers under app/[lang]/@pibrowser/payment/api/.

import { pool } from '../db.js';

const PI_API_KEY = process.env.PI_API_KEY;
const PI_PLATFORM_API_BASE = process.env.PI_PLATFORM_API_BASE || 'https://api.minepi.com/v2';

async function piFetch(path, options = {}) {
  const res = await fetch(`${PI_PLATFORM_API_BASE}${path}`, {
    ...options,
    headers: {
      Authorization: `Key ${PI_API_KEY}`,
      'Content-Type': 'application/json',
      ...(options.headers || {}),
    },
  });

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`Pi Platform API ${path} failed: ${res.status} ${body}`);
  }
  return res.json();
}

/**
 * Step 1 of the payment flow: client SDK reports a created payment id
 * via onReadyForServerApproval. We validate it against our own claim/
 * payment row, then approve it with the Pi Platform.
 */
export async function approvePayment(piPaymentId) {
  const platformPayment = await piFetch(`/payments/${piPaymentId}`);

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const { rows } = await client.query(
      `UPDATE pibrowser_payment.payments
         SET status = 'pending', pi_payment_id = $1
       WHERE pi_uid = $2 AND status = 'created'
         AND amount_requested = $3
       RETURNING *`,
      [piPaymentId, platformPayment.user_uid, platformPayment.amount]
    );

    if (rows.length === 0) {
      throw new Error(`No matching pending payment row for pi_payment_id=${piPaymentId}`);
    }

    await piFetch(`/payments/${piPaymentId}/approve`, { method: 'POST' });

    await client.query(
      `UPDATE pibrowser_payment.payments SET status = 'submitted' WHERE pi_payment_id = $1`,
      [piPaymentId]
    );

    await client.query('COMMIT');
    return rows[0];
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

/**
 * Step 2: client SDK reports the blockchain txid via
 * onReadyForServerCompletion. We confirm the tx on-chain via the Pi
 * Platform, check tolerance, then mark the payment completed.
 */
export async function completePayment(piPaymentId, txid) {
  const completed = await piFetch(`/payments/${piPaymentId}/complete`, {
    method: 'POST',
    body: JSON.stringify({ txid }),
  });

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const { rows } = await client.query(
      `SELECT * FROM pibrowser_payment.payments WHERE pi_payment_id = $1 FOR UPDATE`,
      [piPaymentId]
    );
    if (rows.length === 0) throw new Error(`Unknown pi_payment_id=${piPaymentId}`);
    const payment = rows[0];

    const { rows: tolRows } = await client.query(
      `SELECT pibrowser_payment.fn_within_tolerance($1, $2, $3) AS ok`,
      [payment.amount_requested, completed.amount, payment.tolerance_bps]
    );

    const nextStatus = tolRows[0].ok ? 'confirmed' : 'failed';

    await client.query(
      `UPDATE pibrowser_payment.payments
          SET status = $1, amount_paid = $2, tx_id = $3,
              error_reason = $4
        WHERE pi_payment_id = $5`,
      [
        nextStatus,
        completed.amount,
        txid,
        nextStatus === 'failed' ? 'Amount outside configured tolerance' : null,
        piPaymentId,
      ]
    );

    if (nextStatus === 'confirmed') {
      await client.query(
        `UPDATE pibrowser_payment.payments SET status = 'completed' WHERE pi_payment_id = $1`,
        [piPaymentId]
      );
    }

    if (payment.claim_id) {
      await client.query(
        `UPDATE pibrowser_payment.claims SET status = 'released', updated_at = now()
          WHERE id = $1`,
        [payment.claim_id]
      );
    }

    await client.query('COMMIT');
    return { status: nextStatus === 'failed' ? 'failed' : 'completed', txid };
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

export async function cancelPayment(piPaymentId, reason) {
  await pool.query(
    `UPDATE pibrowser_payment.payments
        SET status = 'cancelled', error_reason = $2
      WHERE pi_payment_id = $1`,
    [piPaymentId, reason || 'Cancelled by user']
  );
}
