// app/[lang]/@pibrowser/payment/page.jsx
import PaymentForm from './components/PaymentForm.jsx';
import PaymentHistoryTable from './components/PaymentHistoryTable.jsx';
import { getDictionary } from '../../../../lib/i18n/getDictionary.js';

export default async function PaymentPage({ params, searchParams }) {
  const { lang } = params;
  const dict = await getDictionary(lang, 'payment');
  const claimId = searchParams?.claim_id || null;

  return (
    <main className="payment-page">
      <header className="payment-page__header">
        <h1>{dict.title || 'Pay with Pi'}</h1>
        <p>{dict.subtitle || 'Complete this payment securely inside Pi Browser.'}</p>
      </header>

      <PaymentForm lang={lang} claimId={claimId} dict={dict} />

      <PaymentHistoryTable lang={lang} dict={dict} />
    </main>
  );
}
