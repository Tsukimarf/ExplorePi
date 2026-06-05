// controllers/accountController.js
const Account = require('../models/Account');
const { fetchAccountOnChain, resolveContractMetadata, CONTRACT_ADDRESS } = require('../config/pi');

/**
 * GET /api/accounts/:wallet
 * Fetch full account profile + metadata.
 */
async function getAccount(req, res) {
  try {
    const { wallet } = req.params;
    const account = await Account.findByWallet(wallet);
    if (!account) {
      return res.status(404).json({ success: false, error: 'Account not found' });
    }
    const metadata = await Account.getMetadata(account.id);
    return res.json({ success: true, data: { ...account, metadata } });
  } catch (err) {
    console.error('[getAccount]', err);
    return res.status(500).json({ success: false, error: err.message });
  }
}

/**
 * POST /api/accounts/register
 * Register or retrieve account by wallet + contract address.
 * Body: { wallet_address, contract_address? }
 */
async function registerAccount(req, res) {
  try {
    const { wallet_address, contract_address } = req.body;
    const contractAddr = contract_address || CONTRACT_ADDRESS;

    if (!wallet_address) {
      return res.status(400).json({ success: false, error: 'wallet_address is required' });
    }

    const account = await Account.upsert(wallet_address, contractAddr);
    await Account.audit(account.id, 'register', { wallet_address, contractAddr }, req.ip);

    return res.status(201).json({ success: true, data: account });
  } catch (err) {
    console.error('[registerAccount]', err);
    return res.status(500).json({ success: false, error: err.message });
  }
}

/**
 * PUT /api/accounts/:wallet/profile
 * Update profile/metadata fields.
 * Body: { username, display_name, bio, avatar_url, website_url,
 *         twitter_handle, github_handle, language, timezone }
 */
async function updateProfile(req, res) {
  try {
    const { wallet } = req.params;
    const account = await Account.findByWallet(wallet);
    if (!account) {
      return res.status(404).json({ success: false, error: 'Account not found' });
    }

    const updated = await Account.updateProfile(account.id, req.body);
    if (!updated) {
      return res.status(400).json({ success: false, error: 'No valid fields to update' });
    }

    await Account.audit(account.id, 'profile_update', req.body, req.ip);
    const fresh = await Account.findByWallet(wallet);
    return res.json({ success: true, data: fresh });
  } catch (err) {
    console.error('[updateProfile]', err);
    return res.status(500).json({ success: false, error: err.message });
  }
}

/**
 * PUT /api/accounts/:wallet/metadata
 * Set arbitrary key-value metadata.
 * Body: { key, value }
 */
async function setMetadata(req, res) {
  try {
    const { wallet } = req.params;
    const { key, value } = req.body;

    if (!key || value === undefined) {
      return res.status(400).json({ success: false, error: 'key and value are required' });
    }

    const account = await Account.findByWallet(wallet);
    if (!account) {
      return res.status(404).json({ success: false, error: 'Account not found' });
    }

    await Account.setMetadata(account.id, key, value, 'app');
    await Account.audit(account.id, 'metadata_set', { key }, req.ip);

    return res.json({ success: true, message: `Metadata '${key}' updated` });
  } catch (err) {
    console.error('[setMetadata]', err);
    return res.status(500).json({ success: false, error: err.message });
  }
}

/**
 * POST /api/accounts/:wallet/sync
 * Pull on-chain account data and sync to DB metadata.
 */
async function syncChain(req, res) {
  try {
    const { wallet } = req.params;
    const account = await Account.findByWallet(wallet);
    if (!account) {
      return res.status(404).json({ success: false, error: 'Account not found' });
    }

    const onChain = await fetchAccountOnChain(wallet);
    if (!onChain) {
      return res.status(404).json({ success: false, error: 'Wallet not found on Pi Network' });
    }

    // Sync chain data entries → metadata table
    await Account.syncChainData(account.id, onChain.data);

    // Store balance as metadata
    const piBalance = onChain.balances.find(b => b.asset_type === 'native');
    if (piBalance) {
      await Account.setMetadata(account.id, 'chain:pi_balance', piBalance.balance, 'chain');
    }

    await Account.audit(account.id, 'chain_sync', { sequence: onChain.sequence }, req.ip);

    return res.json({
      success: true,
      data: {
        wallet,
        sequence:   onChain.sequence,
        balances:   onChain.balances,
        dataKeys:   Object.keys(onChain.data || {}),
      },
    });
  } catch (err) {
    console.error('[syncChain]', err);
    return res.status(500).json({ success: false, error: err.message });
  }
}

/**
 * GET /api/accounts/:wallet/metadata
 * Get all metadata entries for an account.
 */
async function getMetadata(req, res) {
  try {
    const { wallet } = req.params;
    const account = await Account.findByWallet(wallet);
    if (!account) {
      return res.status(404).json({ success: false, error: 'Account not found' });
    }
    const metadata = await Account.getMetadata(account.id);
    return res.json({ success: true, data: metadata });
  } catch (err) {
    console.error('[getMetadata]', err);
    return res.status(500).json({ success: false, error: err.message });
  }
}

/**
 * GET /api/contract
 * Resolve contract metadata from Pi Network.
 */
async function getContract(req, res) {
  try {
    const contractAddress = req.query.address || CONTRACT_ADDRESS;
    const meta = await resolveContractMetadata(contractAddress);
    return res.json({ success: true, data: meta });
  } catch (err) {
    console.error('[getContract]', err);
    return res.status(400).json({ success: false, error: err.message });
  }
}

module.exports = {
  getAccount,
  registerAccount,
  updateProfile,
  setMetadata,
  getMetadata,
  syncChain,
  getContract,
};
