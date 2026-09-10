// models/Account.js
const { pool } = require('../config/db');
const { v4: uuidv4 } = require('uuid');

class Account {
  /**
   * Find account by wallet address.
   */
  static async findByWallet(walletAddress) {
    const [rows] = await pool.execute(
      `SELECT a.*, ap.username, ap.display_name, ap.bio, ap.avatar_url,
              ap.website_url, ap.twitter_handle, ap.github_handle,
              ap.language, ap.timezone, ap.is_verified
         FROM accounts a
    LEFT JOIN account_profiles ap ON ap.account_id = a.id
        WHERE a.wallet_address = ?
        LIMIT 1`,
      [walletAddress]
    );
    return rows[0] || null;
  }

  /**
   * Find account by internal ID.
   */
  static async findById(id) {
    const [rows] = await pool.execute(
      `SELECT a.*, ap.username, ap.display_name, ap.bio, ap.avatar_url,
              ap.website_url, ap.twitter_handle, ap.github_handle,
              ap.language, ap.timezone, ap.is_verified
         FROM accounts a
    LEFT JOIN account_profiles ap ON ap.account_id = a.id
        WHERE a.id = ?
        LIMIT 1`,
      [id]
    );
    return rows[0] || null;
  }

  /**
   * Create a new account + empty profile.
   */
  static async create(walletAddress, contractAddress) {
    const id = uuidv4();
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      await conn.execute(
        `INSERT INTO accounts (id, wallet_address, contract_address) VALUES (?, ?, ?)`,
        [id, walletAddress, contractAddress]
      );
      await conn.execute(
        `INSERT INTO account_profiles (id, account_id) VALUES (?, ?)`,
        [uuidv4(), id]
      );
      await conn.commit();
    } catch (err) {
      await conn.rollback();
      throw err;
    } finally {
      conn.release();
    }
    return Account.findById(id);
  }

  /**
   * Upsert account — create if not exists, return existing otherwise.
   */
  static async upsert(walletAddress, contractAddress) {
    let account = await Account.findByWallet(walletAddress);
    if (!account) {
      account = await Account.create(walletAddress, contractAddress);
    }
    return account;
  }

  /**
   * Update profile fields (partial update supported).
   */
  static async updateProfile(accountId, fields) {
    const allowed = [
      'username', 'display_name', 'bio', 'avatar_url',
      'website_url', 'twitter_handle', 'github_handle',
      'language', 'timezone',
    ];
    const updates = [];
    const values  = [];
    for (const key of allowed) {
      if (fields[key] !== undefined) {
        updates.push(`${key} = ?`);
        values.push(fields[key]);
      }
    }
    if (updates.length === 0) return false;
    values.push(accountId);
    await pool.execute(
      `UPDATE account_profiles SET ${updates.join(', ')} WHERE account_id = ?`,
      values
    );
    return true;
  }

  /**
   * Set arbitrary metadata key-value.
   */
  static async setMetadata(accountId, key, value, source = 'app') {
    await pool.execute(
      `INSERT INTO account_metadata (id, account_id, meta_key, meta_value, source)
       VALUES (?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE meta_value = VALUES(meta_value),
                               source     = VALUES(source),
                               updated_at = CURRENT_TIMESTAMP`,
      [uuidv4(), accountId, key, String(value), source]
    );
  }

  /**
   * Get all metadata for an account.
   */
  static async getMetadata(accountId) {
    const [rows] = await pool.execute(
      `SELECT meta_key, meta_value, source, updated_at
         FROM account_metadata
        WHERE account_id = ?
        ORDER BY meta_key`,
      [accountId]
    );
    return rows;
  }

  /**
   * Sync on-chain data entries into metadata table (source='chain').
   */
  static async syncChainData(accountId, dataAttr) {
    if (!dataAttr || typeof dataAttr !== 'object') return;
    for (const [key, b64val] of Object.entries(dataAttr)) {
      const decoded = Buffer.from(b64val, 'base64').toString('utf8');
      await Account.setMetadata(accountId, `chain:${key}`, decoded, 'chain');
    }
  }

  /**
   * Write to audit log.
   */
  static async audit(accountId, action, details, ip) {
    await pool.execute(
      `INSERT INTO audit_log (account_id, action, details, ip_address)
       VALUES (?, ?, ?, ?)`,
      [accountId || null, action, JSON.stringify(details), ip || null]
    );
  }
}

module.exports = Account;
