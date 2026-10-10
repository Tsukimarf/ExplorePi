export class ApiClientError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}

let accessToken = null;
/** Call with auth.accessToken from Pi.authenticate(). */
export const setAccessToken = (t) => { accessToken = t; };

export async function apiFetch(path, { method = 'GET', body, signal } = {}) {
  const res = await fetch(`/api${path}`, {
    method, signal,
    headers: { 'Content-Type': 'application/json', ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => null);
  if (!res.ok || !json?.ok) throw new ApiClientError(res.status, json?.error?.code ?? 'error', json?.error?.message ?? res.statusText);
  return json.data;
}

export const paymentsApi = {
  list:     (q = {}) => apiFetch(`/payments?${new URLSearchParams(Object.entries(q).filter(([, v]) => v))}`),
  get:      (id) => apiFetch(`/payments/${id}`),
  create:   (p) => apiFetch('/payments', { method: 'POST', body: p }),
  approve:  (id, piPaymentId) => apiFetch(`/payments/${id}/approve`, { method: 'POST', body: { piPaymentId } }),
  complete: (id, txid) => apiFetch(`/payments/${id}/complete`, { method: 'POST', body: { txid } }),
  cancel:   (id) => apiFetch(`/payments/${id}/cancel`, { method: 'POST' }),
};

export const exchangeApi = {
  rates:    () => apiFetch('/exchange/rates'),
  addRate:  (r) => apiFetch('/exchange/rates', { method: 'POST', body: r }),
  list:     (q = {}) => apiFetch(`/exchange/orders?${new URLSearchParams(Object.entries(q).filter(([, v]) => v))}`),
  get:      (id) => apiFetch(`/exchange/orders/${id}`),
  create:   (o) => apiFetch('/exchange/orders', { method: 'POST', body: o }),
  approve:  (id) => apiFetch(`/exchange/orders/${id}/approve`, { method: 'POST' }),
  complete: (id, txid) => apiFetch(`/exchange/orders/${id}/complete`, { method: 'POST', body: { txid } }),
  cancel:   (id) => apiFetch(`/exchange/orders/${id}/cancel`, { method: 'POST' }),
};

export const transaksiApi = {
  list: (q = {}) => apiFetch(`/transaksi?${new URLSearchParams(Object.entries(q).filter(([, v]) => v))}`),
};
