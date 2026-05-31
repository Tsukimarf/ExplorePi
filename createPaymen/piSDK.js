// pi-sdk-js — ESM only (2026)
import { PiSdkBase } from 'pi-sdk-js'

const pi = new PiSdkBase()

// Auth — panggil saat mount atau user click
export async function connectPi() {
  await pi.connect()
  return pi.user  // { name, uid, ... }
}

// U2A Payment (User to App) — claim/purchase
export function createPayment({ amount, memo, metadata, onApproval, onComplete, onCancel, onError }) {
  return pi.createPayment(
    { amount, memo, metadata },
    {
      onReadyForServerApproval: (paymentId) => onApproval(paymentId),
      onReadyForServerCompletion: (paymentId, txid) => onComplete(paymentId, txid),
      onCancel:  (paymentId) => onCancel(paymentId),
      onError:   (error, payment) => onError(error, payment),
    }
  )
}
