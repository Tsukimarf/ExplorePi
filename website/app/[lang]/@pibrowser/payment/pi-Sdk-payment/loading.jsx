// app/[lang]/@pibrowser/payment/loading.jsx
export default function PaymentLoading() {
  return (
    <div className="payment-page payment-page--loading" aria-busy="true">
      <div className="skeleton skeleton--title" />
      <div className="skeleton skeleton--card" />
      <div className="skeleton skeleton--row" />
      <div className="skeleton skeleton--row" />
    </div>
  );
}
