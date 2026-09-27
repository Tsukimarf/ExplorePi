'use client';
// app/[lang]/@pibrowser/payment/components/PaymentForm.jsx
import { useState, useCallback } from 'react';
import { authenticatePiUser, createPiPayment, isPiBrowser } from '../../../../../../lib/pi/piSDK.js';
import PaymentStatusCard from './PaymentStatusCard.jsx';
import QRPaymentDisplay from './QRPaymentDisplay.jsx';

const STEPS = {
  IDLE: 'idle',
  AUTHENTICATING: 'authenticating',
  CREATING: 'creating',
  APPROVING: 'approving',
  SUBMITTED: 'submitted',
  COMPLETING: 'completing',
  COMPLETED: 'completed',
  ERROR: 'error',
};

export default function PaymentForm({ lang, claimId, dict }) {
  const [amount, setAmount] = useState('');
  const [memo, setMemo] = useState('');
  const [toAddress, setToAddress] = useState('');
  const [step, setStep] = useState(STEPS.IDLE);
  const [payment, setPayment] = useState(null);
  const [errorMsg, setErrorMsg] = useState(null);

  const callApi = useCallback(async (url, body) => {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `Request to ${url} failed`);
    return data;
  }, []);

  const handleSubmit = useCallback(
    async (e) => {
      e.preventDefault();
      setErrorMsg(null);

      if (!isPiBrowser() && process.env.NODE_ENV === 'production') {
        setErrorMsg(dict.errorNotPiBrowser || 'Open this page inside Pi Browser to pay.');
        setStep(STEPS.ERROR);
        return;
      }

      try {
        setStep(STEPS.AUTHENTICATING);
        const user = await authenticatePiUser((incomplete) => {
          console.warn('Incomplete payment found on auth:', incomplete);
        });

        setStep(STEPS.CREATING);
        const { payment: row } = await callApi(`/${lang}/payment/api/payments`, {
          pi_uid: user.uid,
          pi_username: user.username,
          to_address: toAddress,
          amount: Number(amount),
          memo,
          claim_id: claimId,
        });
        setPayment(row);

        await createPiPayment(
          { amount: Number(amount), memo, metadata: { claim_id: claimId, db_payment_id: row.id } },
          {
            onReadyForServerApproval: async (piPaymentId) => {
              setStep(STEPS.APPROVING);
              await callApi(`/${lang}/payment/api/payments/${piPaymentId}`, { action: 'approve' });
              setStep(STEPS.SUBMITTED);
            },
            onReadyForServerCompletion: async (piPaymentId, txid) => {
              setStep(STEPS.COMPLETING);
              await callApi(`/${lang}/payment/api/payments/${piPaymentId}`, {
                action: 'complete',
                txid,
              });
              setStep(STEPS.COMPLETED);
            },
            onCancel: async (piPaymentId) => {
              await callApi(`/${lang}/payment/api/payments/${piPaymentId}`, {
                action: 'cancel',
                reason: 'User cancelled in Pi Browser',
              });
              setStep(STEPS.IDLE);
            },
            onError: (error) => {
              console.error('Pi payment error:', error);
              setErrorMsg(error?.message || String(error));
              setStep(STEPS.ERROR);
            },
          }
        );
      } catch (err) {
        console.error(err);
        setErrorMsg(err.message);
        setStep(STEPS.ERROR);
      }
    },
    [amount, memo, toAddress, claimId, lang, dict, callApi]
  );

  const busy = ![STEPS.IDLE, STEPS.ERROR, STEPS.COMPLETED].includes(step);

  return (
    <div className="payment-form-wrap">
      <form className="payment-form" onSubmit={handleSubmit}>
        <label className="payment-form__field">
          <span>{dict.labelAmount || 'Amount (Pi)'}</span>
          <input
            type="number"
            min="0.0000001"
            step="0.0000001"
            required
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            disabled={busy}
          />
        </label>

        <label className="payment-form__field">
          <span>{dict.labelToAddress || 'Recipient wallet address'}</span>
          <input
            type="text"
            required
            value={toAddress}
            onChange={(e) => setToAddress(e.target.value)}
            disabled={busy}
          />
        </label>

        <label className="payment-form__field">
          <span>{dict.labelMemo || 'Memo (optional)'}</span>
          <input type="text" value={memo} onChange={(e) => setMemo(e.target.value)} disabled={busy} />
        </label>

        <button type="submit" className="payment-form__submit" disabled={busy}>
          {busy ? dict.buttonProcessing || 'Processing…' : dict.buttonPay || 'Pay with Pi'}
        </button>
      </form>

      <PaymentStatusCard step={step} errorMsg={errorMsg} dict={dict} />

      {step === STEPS.SUBMITTED && payment?.to_address && (
        <QRPaymentDisplay address={payment.to_address} amount={amount} />
      )}
    </div>
  );
}
