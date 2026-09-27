'use client';
// app/[lang]/@pibrowser/payment/components/PaymentHistoryTable.jsx
import { useEffect, useState } from 'react';

export default function PaymentHistoryTable({ lang, dict }) {
  const [payments, setPayments] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      try {
        const res = await fetch(`/${lang}/payment/api/payments?limit=10`);
        const data = await res.json();
        if (!cancelled) setPayments(data.payments || []);
      } catch (err) {
        console.error('Failed to load payment history:', err);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    load();
    const interval = setInterval(load, 15000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [lang]);

  if (loading) return null;
  if (payments.length === 0) {
    return <p className="payment-history__empty">{dict.emptyHistory || 'No payments yet.'}</p>;
  }

  return (
    <table className="payment-history">
      <thead>
        <tr>
          <th>{dict.colDate || 'Date'}</th>
          <th>{dict.colAmount || 'Amount'}</th>
          <th>{dict.colStatus || 'Status'}</th>
          <th>{dict.colTx || 'Tx'}</th>
        </tr>
      </thead>
      <tbody>
        {payments.map((p) => (
          <tr key={p.id}>
            <td>{new Date(p.created_at).toLocaleString()}</td>
            <td>{p.amount_requested} π</td>
            <td>
              <span className={`badge badge--${p.status}`}>{p.status}</span>
            </td>
            <td>
              {p.tx_id ? (
                <a
                  href={`https://stellar.expert/explorer/public/tx/${p.tx_id}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  {p.tx_id.slice(0, 8)}…
                </a>
              ) : (
                '—'
              )}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
