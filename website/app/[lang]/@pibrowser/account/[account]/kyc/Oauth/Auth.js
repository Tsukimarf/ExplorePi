import { Router } from 'express';
import crypto from 'node:crypto';
import { query } from '../db.js';
import { oauthConfig } from '../oauth-config.js';
import { putSecretEnsureKey } from '../pq.js';

const r = Router();
const wrap = (fn) => (req, res, next) => fn(req, res, next).catch(next);

const b64url = (buf) => buf.toString('base64url');
const randomToken = () => crypto.randomBytes(32).toString('hex');
const sanitizeUsername = (s) =>
  String(s || '').toLowerCase().replace(/[^a-z0-9_.-]/g, '').slice(0, 32);

async function uniqueUsername(base) {
  const root = sanitizeUsername(base) || 'user';
  const padded = root.length >= 3 ? root : (root + '___').slice(0, 3);
  for (let i = 0; i < 5; i++) {
    const candidate = i === 0 ? padded : `${padded}_${crypto.randomBytes(2).toString('hex')}`.slice(0, 32);
    const { rows } = await query('SELECT 1 FROM accounts WHERE username = $1', [candidate]);
    if (!rows[0]) return candidate;
  }
  return `user_${crypto.randomBytes(6).toString('hex')}`;
}

// GET /api/auth/:provider/start -> { url } untuk frontend redirect ke provider
r.get('/auth/:provider/start', wrap(async (req, res) => {
  const cfg = oauthConfig(req.params.provider);
  if (!cfg) return res.status(404).json({ error: 'provider_not_configured' });

  const state = randomToken();
  const codeVerifier = b64url(crypto.randomBytes(32));
  const codeChallenge = b64url(crypto.createHash('sha256').update(codeVerifier).digest());
  const redirectTo = typeof req.query.redirect_to === 'string' ? req.query.redirect_to : null;

  await query(
    'INSERT INTO oauth_states (state, provider, code_verifier, redirect_to) VALUES ($1,$2,$3,$4)',
    [state, cfg.provider, codeVerifier, redirectTo]
  );

  const url = new URL(cfg.authorizeUrl);
  url.searchParams.set('client_id', cfg.clientId);
  url.searchParams.set('redirect_uri', cfg.redirectUri);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('scope', cfg.scope);
  url.searchParams.set('state', state);
  url.searchParams.set('code_challenge', codeChallenge);
  url.searchParams.set('code_challenge_method', 'S256');

  res.json({ url: url.toString() });
}));

// GET /api/auth/:provider/callback?code=...&state=...
r.get('/auth/:provider/callback', wrap(async (req, res) => {
  const cfg = oauthConfig(req.params.provider);
  if (!cfg) return res.status(404).json({ error: 'provider_not_configured' });

  const { code, state } = req.query;
  if (!code || !state) return res.status(400).json({ error: 'missing_code_or_state' });

  const { rows: stateRows } = await query(
    `DELETE FROM oauth_states WHERE state = $1 AND provider = $2 AND expires_at > now()
     RETURNING code_verifier, redirect_to`,
    [state, cfg.provider]
  );
  const stateRow = stateRows[0];
  if (!stateRow) return res.status(400).json({ error: 'state_invalid_or_expired' });

  const tokenRes = await fetch(cfg.tokenUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code: String(code),
      redirect_uri: cfg.redirectUri,
      client_id: cfg.clientId,
      client_secret: cfg.clientSecret,
      code_verifier: stateRow.code_verifier,
    }),
  });
  const token = await tokenRes.json().catch(() => ({}));
  if (!tokenRes.ok || !token.access_token) {
    return res.status(502).json({ error: 'token_exchange_failed' });
  }

  const profileRes = await fetch(cfg.userinfoUrl, {
    headers: { authorization: `Bearer ${token.access_token}` },
  });
  const profile = await profileRes.json().catch(() => ({}));
  const providerUserId = String(profile.sub || profile.uid || profile.id || '');
  if (!profileRes.ok || !providerUserId) {
    return res.status(502).json({ error: 'userinfo_failed' });
  }

  let { rows: linkRows } = await query(
    `SELECT id, account_id FROM oauth_accounts WHERE provider = $1 AND provider_user_id = $2`,
    [cfg.provider, providerUserId]
  );
  let accountId, oauthAccountId;

  if (linkRows[0]) {
    ({ account_id: accountId, id: oauthAccountId } = linkRows[0]);
    await query(
      `UPDATE oauth_accounts SET token_expires_at = $2, scope = $3, raw_profile = $4
         WHERE id = $1`,
      [oauthAccountId, token.expires_in ? new Date(Date.now() + token.expires_in * 1000) : null,
       token.scope || null, JSON.stringify(profile)]
    );
  } else {
    const username = await uniqueUsername(profile.username || profile.name || profile.email);
    const { rows } = await query(
      'INSERT INTO accounts (username) VALUES ($1) RETURNING id', [username]
    );
    accountId = rows[0].id;
    await query('INSERT INTO account_profiles (account_id, display_name) VALUES ($1,$2)',
      [accountId, profile.name || profile.username || null]);

    const inserted = await query(
      `INSERT INTO oauth_accounts
         (account_id, provider, provider_user_id, token_expires_at, scope, raw_profile)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [accountId, cfg.provider, providerUserId,
       token.expires_in ? new Date(Date.now() + token.expires_in * 1000) : null,
       token.scope || null, JSON.stringify(profile)]
    );
    oauthAccountId = inserted.rows[0].id;
  }

  // Token disimpan terenkripsi (ML-KEM + AES-GCM), bukan di oauth_accounts.
  await putSecretEnsureKey(accountId, `oauth_access_token:${cfg.provider}`, token.access_token);
  if (token.refresh_token) {
    await putSecretEnsureKey(accountId, `oauth_refresh_token:${cfg.provider}`, token.refresh_token);
  }

  const sessionToken = randomToken();
  const tokenHash = crypto.createHash('sha256').update(sessionToken).digest();
  await query(
    `INSERT INTO sessions (account_id, token_hash, oauth_account_id, login_method, user_agent, ip, expires_at)
     VALUES ($1,$2,$3,'oauth',$4,$5, now() + interval '7 days')`,
    [accountId, tokenHash, oauthAccountId, req.get('user-agent') || null, req.ip]
  );
  await query(
    `INSERT INTO audit_logs (account_id, action, detail, ip) VALUES ($1,'auth.oauth_login',$2,$3)`,
    [accountId, JSON.stringify({ provider: cfg.provider }), req.ip]
  );

  res.json({ token: sessionToken, redirect_to: stateRow.redirect_to || null });
}));

export default r;
