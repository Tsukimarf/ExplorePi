import PiNetwork from 'pi-backend'

const pi = new PiNetwork(
  process.env.PI_API_KEY,
  process.env.PI_WALLET_PRIVATE_SEED  // starts with 'S...'
)

// Step 1: Server-side approve (dipanggil dari onReadyForServerApproval callback)
export async function approvePayment(paymentId) {
  await pi.approvePayment(paymentId)
}

// Step 2: Submit ke blockchain (dipanggil dari onReadyForServerCompletion)
export async function completePayment(paymentId, txid) {
  const payment = await pi.completePayment(paymentId, txid)
  return payment
}

// A2U — App to User (reward/claim ke user)
export async function rewardUser(userUid, amount, memo, productId) {
  const paymentId = await pi.createPayment({
    amount,
    memo,
    metadata: { productId },
    uid: userUid,
  })
  const txid = await pi.submitPayment(paymentId)
  await pi.completePayment(paymentId, txid)
  return { paymentId, txid }
}
