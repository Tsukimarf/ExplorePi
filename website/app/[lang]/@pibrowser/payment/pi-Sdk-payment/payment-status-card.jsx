'use client';
// app/[lang]/@pibrowser/payment/components/PaymentStatusCard.jsx

const STEP_LABELS = {
  idle: { label: 'Ready', tone: 'neutral' },
  authenticating: { label: 'Authenticating with Pi…', tone: 'pending' },
  creating: { label: 'Creating payment record…', tone: 'pending' },
  approving: { label: 'Awaiting server approval…', tone: 'pending' },
  submitted: { label: 'Submitted — confirm in Pi Browser', tone: 'pending' },
  completing: { label: 'Confirming on-chain…', tone: 'pending' },
  completed: { label: 'Payment completed ✅', tone: 'success' },
  error: { label: 'Payment failed', tone: 'error' },
};

export default function PaymentStatusCard({ step, errorMsg, dict }) {
  const info = STEP_LABELS[step] || STEP_LABELS.idle;

  if (step === 'idle') return null;

  return (
    <div className={`payment-status payment-status--${info.tone}`} role="status">
      <span className="payment-status__dot" />
      <span className="payment-status__label">{dict?.[`status_${step}`] || info.label}</span>
      {step === 'error' && errorMsg && (
        <p className="payment-status__error">{errorMsg}</p>
      )}
    </div>
  );
}
