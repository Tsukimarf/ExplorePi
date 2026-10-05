// lib/pi/piSDK.js
// Client-side wrapper around the Pi SDK (pi-sdk-js, ESM pattern).
// Used exclusively inside app/[lang]/@pibrowser/payment/* client components.

let piInstance = null;

const PI_SANDBOX = process.env.NEXT_PUBLIC_PI_SANDBOX === 'true';
const PI_VERSION = '2.0';

/**
 * Lazily loads and initializes the Pi SDK from the Pi Browser injected
 * global (window.Pi) or falls back to the pi-sdk-js ESM package for
 * non-Pi-Browser dev environments.
 */
export async function initPiSDK() {
  if (piInstance) return piInstance;

  if (typeof window === 'undefined') {
    throw new Error('initPiSDK() must run in a browser context (Pi Browser).');
  }

  if (window.Pi) {
    window.Pi.init({ version: PI_VERSION, sandbox: PI_SANDBOX });
    piInstance = window.Pi;
    return piInstance;
  }

  // Dev fallback: pi-sdk-js ESM package, mirrors window.Pi surface
  const mod = await import('pi-sdk-js');
  const { PiSDK } = await import('pi-sdk-js');
  const Pi = new PiSDK({ version: PI_VERSION, sandbox: PI_SANDBOX });
  await Pi.init();
  piInstance = Pi;
  return piInstance;

/**
 * Authenticates the user against Pi Network, requesting the scopes
 * needed to create a payment on their behalf.
 */
export async function authenticatePiUser(onIncompletePaymentFound) {
  const Pi = await initPiSDK();
  const scopes = ['username', 'payments'];

  const auth = await Pi.authenticate(scopes, (payment) => {
    if (typeof onIncompletePaymentFound === 'function') {
      onIncompletePaymentFound(payment);
    }
  });

  return {
    uid: auth.user.uid,
    username: auth.user.username,
    accessToken: auth.accessToken,
  };
}

/**
 * Creates a Pi payment from the client. `paymentData` mirrors the Pi
 * Platform payment object; callbacks are wired to the /api/payments
 * route handlers in this module for server-side approval/completion.
 */
export async function createPiPayment({ amount, memo, metadata }, callbacks) {
  const Pi = await initPiSDK();

  return Pi.createPayment(
    { amount, memo, metadata },
    {
      onReadyForServerApproval: callbacks.onReadyForServerApproval,
      onReadyForServerCompletion: callbacks.onReadyForServerCompletion,
      onCancel: callbacks.onCancel,
      onError: callbacks.onError,
    }
  );
}

export function isPiBrowser() {
  return typeof window !== 'undefined' && Boolean(window.Pi);
}
