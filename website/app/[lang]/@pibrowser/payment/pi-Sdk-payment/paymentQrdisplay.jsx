'use client';
// app/[lang]/@pibrowser/payment/components/QRPaymentDisplay.jsx
// Renders a lightweight QR (via public QR image API) showing the
// Stellar destination address + amount for manual verification.

export default function QRPaymentDisplay({ address, amount }) {
  const payload = encodeURIComponent(`${address}?amount=${amount}`);
  const qrSrc = `https://api.qrserver.com/v1/create-qr-code/?size=180x180&data=${payload}`;

  return (
    <div className="qr-payment-display">
      <img src={qrSrc} alt="Payment QR code" width={180} height={180} />
      <p className="qr-payment-display__address" title={address}>
        {address.slice(0, 6)}…{address.slice(-6)}
      </p>
      <p className="qr-payment-display__amount">{amount} π</p>
    </div>
  );
}
