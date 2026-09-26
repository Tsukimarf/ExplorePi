/**
 * @pibrowser/blockchain — Pi SDK integration (2026 ESM migration)
 *
 * Client-side: pi-sdk-js  (window.Pi bridge, wraps Pi Browser's injected SDK)
 * Server-side: pi-backend (server-to-server verification / Horizon+Soroban RPC)
 *
 * Chains supported by default: Pi Network (Stellar/Soroban), Solana, Ethereum.
 */

import { PiSDK } from 'pi-sdk-js';
import { PiBackend } from 'pi-backend';

// ---------------------------------------------------------------------------
// Chain registry — drives both the UI selector and the DB-backed metadata
// ---------------------------------------------------------------------------
export const CHAINS = Object.freeze({
  pi: {
    id: 'pi',
    label: 'Pi Network',
    kind: 'stellar-soroban',
    network: process.env.PI_NETWORK_ENV || 'mainnet',
    horizonUrl: process.env.PI_HORIZON_URL || 'https://api.mainnet.minepi.com',
    sorobanRpcUrl: process.env.PI_SOROBAN_RPC_URL || 'https://soroban-rpc.minepi.com',
  },
  solana: {
    id: 'solana',
    label: 'Solana',
    kind: 'solana',
    network: process.env.SOLANA_NETWORK_ENV || 'mainnet-beta',
    rpcUrl: process.env.SOLANA_RPC_URL || 'https://api.mainnet-beta.solana.com',
  },
  ethereum: {
    id: 'ethereum',
    label: 'Ethereum',
    kind: 'evm',
    network: process.env.ETH_NETWORK_ENV || 'mainnet',
    rpcUrl: process.env.ETH_RPC_URL || 'https://cloudflare-eth.com',
  },
});

// ---------------------------------------------------------------------------
// Client SDK (browser / Pi Browser webview)
// ---------------------------------------------------------------------------
let clientSdk = null;

export function getClientSDK() {
  if (typeof window === 'undefined') {
    throw new Error('getClientSDK() must run in the browser (Pi Browser webview).');
  }
  if (!clientSdk) {
    clientSdk = new PiSDK({
      version: '2.0',
      sandbox: process.env.NEXT_PUBLIC_PI_SANDBOX === 'true',
    });
  }
  return clientSdk;
}

export async function initPiClient() {
  const sdk = getClientSDK();
  await sdk.init();
  return sdk;
}

export async function authenticatePi(scopes = ['username', 'payments', 'wallet_address']) {
  const sdk = getClientSDK();
  return sdk.authenticate(scopes, onIncompletePaymentFound);
}

function onIncompletePaymentFound(payment) {
  // Delegate to the existing payment reconciliation flow (createPaymen/ module).
  console.warn('[piSDK] incomplete payment found, forwarding to reconciliation', payment?.identifier);
  return fetch('/api/payments/reconcile', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payment),
  }).catch((err) => console.error('[piSDK] reconciliation forward failed', err));
}

// ---------------------------------------------------------------------------
// Server SDK (Next.js route handlers / server components)
// ---------------------------------------------------------------------------
let backend = null;

export function getPiBackend() {
  if (!backend) {
    backend = new PiBackend({
      apiKey: process.env.PI_SERVER_API_KEY,
      network: CHAINS.pi.network,
      horizonUrl: CHAINS.pi.horizonUrl,
      sorobanRpcUrl: CHAINS.pi.sorobanRpcUrl,
    });
  }
  return backend;
}

/**
 * Unified "get chain explorer data" call used by the blockchain page.
 * Falls back gracefully per-chain so one bad RPC doesn't blank the page.
 */
export async function getChainSnapshot(chainId) {
  const chain = CHAINS[chainId];
  if (!chain) throw new Error(`Unknown chain: ${chainId}`);

  try {
    if (chain.kind === 'stellar-soroban') {
      const pb = getPiBackend();
      const [ledger, contracts] = await Promise.all([
        pb.horizon.getLatestLedger(),
        pb.soroban.getRecentContractEvents({ limit: 25 }),
      ]);
      return { chain: chain.id, ledger, contracts, fetchedAt: new Date().toISOString() };
    }
    if (chain.kind === 'solana') {
      const res = await fetch(chain.rpcUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getSlot' }),
      });
      const { result: slot } = await res.json();
      return { chain: chain.id, slot, fetchedAt: new Date().toISOString() };
    }
    if (chain.kind === 'evm') {
      const res = await fetch(chain.rpcUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_blockNumber', params: [] }),
      });
      const { result: blockHex } = await res.json();
      return { chain: chain.id, blockNumber: parseInt(blockHex, 16), fetchedAt: new Date().toISOString() };
    }
  } catch (err) {
    console.error(`[piSDK] getChainSnapshot(${chainId}) failed`, err);
    return { chain: chain.id, error: 'snapshot_unavailable', fetchedAt: new Date().toISOString() };
  }
}

export async function getAllChainSnapshots() {
  const ids = Object.keys(CHAINS);
  const snapshots = await Promise.all(ids.map(getChainSnapshot));
  return Object.fromEntries(snapshots.map((s) => [s.chain, s]));
}
