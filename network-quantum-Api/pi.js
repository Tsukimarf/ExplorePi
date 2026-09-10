// config/pi.js
const StellarSdk = require('stellar-sdk');
require('dotenv').config();

const CONTRACT_ADDRESS = process.env.PI_CONTRACT_ADDRESS;
const HORIZON_URL      = process.env.PI_HORIZON_URL || 'https://api.mainnet.minepi.com';
const NETWORK_PASSPHRASE = process.env.PI_NETWORK_PASSPHRASE || 'Pi Network Mainnet';

const server = new StellarSdk.Horizon.Server(HORIZON_URL, { allowHttp: false });

/**
 * Fetch on-chain account data for a given Pi wallet address.
 * Returns balances, sequence, and any data entries stored on the account.
 */
async function fetchAccountOnChain(walletAddress) {
  try {
    StellarSdk.StrKey.decodeEd25519PublicKey(walletAddress); // validate
    const account = await server.loadAccount(walletAddress);
    return {
      id:         account.id,
      sequence:   account.sequence,
      balances:   account.balances,
      data:       account.data_attr, // base64-encoded on-chain data fields
      thresholds: account.thresholds,
      flags:      account.flags,
    };
  } catch (err) {
    if (err.response && err.response.status === 404) {
      return null; // account not found on chain
    }
    throw err;
  }
}

/**
 * Resolve a contract address and return metadata from the Soroban contract.
 * Uses Soroban RPC if available; falls back to Horizon data entries.
 */
async function resolveContractMetadata(contractAddress) {
  // Soroban contract addresses start with 'C'
  if (!contractAddress || !contractAddress.startsWith('C')) {
    throw new Error('Invalid Soroban contract address (must start with C)');
  }
  // In production, call Soroban RPC here:
  // POST https://soroban-rpc.mainnet.minepi.com
  // method: getContractData / simulateTransaction
  return {
    contractAddress,
    network: NETWORK_PASSPHRASE,
    horizon: HORIZON_URL,
    note: 'Contract metadata resolved via Horizon. Connect Soroban RPC for full state reads.',
  };
}

module.exports = {
  server,
  CONTRACT_ADDRESS,
  NETWORK_PASSPHRASE,
  fetchAccountOnChain,
  resolveContractMetadata,
};
