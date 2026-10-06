import { Router } from 'express';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';

const r = Router();
const wrap = (fn) => (req, res, next) => fn(req, res, next).catch(next);
const DOCUMENT_TYPES = new Set(['passport', 'national_id', 'drivers_license']);

// Catatan: dokumen identitas (foto KTP/paspor) JANGAN diunggah lewat endpoint
// ini. Alur yang benar: frontend mengarahkan pengguna ke halaman hosted milik
// provider KYC, lalu provider memanggil webhook kita untuk update status.
// Endpoint di bawah hanya mengelola STATUS verifikasi, bukan dokumennya.

r.get('/me/kyc', requireAuth, wrap(async (req, res) => {
  const { rows } = await query(
    `SELECT status, provider, document_type, submitted_at, reviewed_at, rejection_reason
       FROM kyc_verifications WHERE account_id = $1`,
    [req.account.id]
  );
  res.json(rows[0] || { status: 'unverified', provider: null, document_type: null });
}));

r.post('/me/kyc', requireAuth, wrap(async (req, res) => {
  const { provider, document_type } = req.body || {};
  if (!document_type || !DOCUMENT_TYPES.has(document_type)) {
    return res.status(400).json({ error: 'document_type_invalid' });
  }

  const current = await query(
    'SELECT status FROM kyc_verifications WHERE account_id = $1', [req.account.id]
  );
  if (current.rows[0] && ['pending', 'verified'].includes(current.rows[0].status)) {
    return res.status(409).json({ error: 'kyc_already_in_progress', status: current.rows[0].status });
  }

  const { rows } = await query(
    `INSERT INTO kyc_verifications (account_id, status, provider, document_type, submitted_at)
     VALUES ($1,'pending',$2,$3, now())
     ON CONFLICT (account_id) DO UPDATE SET
       status = 'pending', provider = EXCLUDED.provider, document_type = EXCLUDED.document_type,
       submitted_at = now(), rejection_reason = NULL
     RETURNING status, provider, document_type, submitted_at`,
    [req.account.id, provider || null, document_type]
  );

  await query(
    `INSERT INTO audit_logs (account_id, action, detail, ip) VALUES ($1,'kyc.submit',$2,$3)`,
    [req.account.id, JSON.stringify({ document_type }), req.ip]
  );
  res.status(201).json(rows[0]);
}));

export default r;
