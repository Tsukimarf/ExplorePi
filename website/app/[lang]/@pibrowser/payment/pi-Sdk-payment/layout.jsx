// app/[lang]/@pibrowser/payment/layout.jsx
import './payment.css';

export const metadata = {
  title: 'Pi Payment · ExplorePi',
  description: 'Pi Network payment flow for ExplorePi Pi Browser',
};

export default function PaymentLayout({ children, params }) {
  return (
    <section className="pibrowser-payment" data-lang={params?.lang || 'en'}>
      {children}
    </section>
  );
}
