// app/[lang]/@pibrowser/payment/api/payments/route.js
import { NextResponse } from 'next/server';
import { pool } from '../../../../../../lib/db.js';

export async function POST(req, { params }) {
  const { lang } = params;
  const body = await req.json();
  const { pi_uid, pi_username, to_address, amount, memo, claim_id, metadata } = body;

  if (!pi_uid || !to_address || !Number.isFinite(Number(amount)) || Number(amount) <= 0) {
    return NextResponse.json(
      { error: 'pi_uid, to_address and amount are required' },
      { status: 400 }
    );
  }

  try {
    const { rows } = await pool.query(
      `INSERT INTO pibrowser_payment.payments
         (claim_id, pi_uid, pi_username, to_address, amount_requested, memo, lang)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       RETURNING *`,
      [claim_id || null, pi_uid, pi_username || null, to_address, amount, memo || null, lang || 'en']
    );

    return NextResponse.json({ payment: rows[0] }, { status: 201 });
  } catch (err) {
    console.error('[payments.create]', err);
    return NextResponse.json({ error: 'Failed to create payment' }, { status: 500 });
  }
}

export async function GET(req) {
  const { searchParams } = new URL(req.url);
  const pi_uid = searchParams.get('pi_uid');
  const status = searchParams.get('status');
  const limit = Math.min(Number(searchParams.get('limit')) || 25, 100);

  const conditions = [];
  const values = [];

  if (pi_uid) {
    values.push(pi_uid);
    conditions.push(`pi_uid = $${values.length}`);
  }
  if (status) {
    values.push(status);
    conditions.push(`status = $${values.length}`);
  }

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  values.push(limit);

  try {
    const { rows } = await pool.query(
      `SELECT id, pi_payment_id, pi_uid, pi_username, to_address, amount_requested,
              amount_paid, tx_id, status, lang, created_at, completed_at
         FROM pibrowser_payment.payments
         ${where}
        ORDER BY created_at DESC
        LIMIT $${values.length}`,
      values
    );
    return NextResponse.json({ payments: rows });
  } catch (err) {
    console.error('[payments.list]', err);
    return NextResponse.json({ error: 'Failed to list payments' }, { status: 500 });
  }
}
