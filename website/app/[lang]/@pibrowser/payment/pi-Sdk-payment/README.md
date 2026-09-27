# @pibrowser/payment — ExplorePi payment module

Rebuilt payment UI app for the `@pibrowser` parallel-route slot at
`website/app/[lang]/@pibrowser/payment/`. Full database + backend + frontend
folder structure, ready to drop into the `Tsukimarf-patch-2` branch.

## Folder structure

```
explorepi-payment/
├── app/[lang]/@pibrowser/payment/
│   ├── layout.jsx              # route-slot layout, injects payment.css
│   ├── page.jsx                # server component: i18n dict + form + history
│   ├── loading.jsx             # skeleton while page.jsx streams
│   ├── payment.css             # scoped styling (Pi Browser dark theme)
│   ├── components/
│   │   ├── PaymentForm.jsx         # client: drives the Pi SDK payment flow
│   │   ├── PaymentStatusCard.jsx   # client: step indicator
│   │   ├── QRPaymentDisplay.jsx    # client: destination QR + amount
│   │   └── PaymentHistoryTable.jsx # client: polls /api/payments
│   └── api/payments/
│       ├── route.js                # POST create, GET list
│       ├── [id]/route.js           # GET one, POST approve|complete|cancel
│       └── webhook/route.js        # Pi Platform webhook, idempotent
├── lib/
│   ├── db.js                # shared pg Pool
│   └── pi/
│       ├── piSDK.js         # client-side pi-sdk-js wrapper (auth + createPayment)
│       └── piPayment.js     # server-side pi-backend wrapper (approve/complete)
├── db/
│   ├── schema.sql           # claims, payments, webhook_events + triggers/views
│   └── seed.sql             # demo data (3 claims, 3 payments, 1 webhook event)
├── scripts/
│   └── reconcile_payments.py  # Stellar-ledger reconciliation cron job
├── package.json
└── .env.example
```

## Install

1. Copy `app/[lang]/@pibrowser/payment/`, `lib/pi/`, `lib/db.js`, `db/`, and
   `scripts/` into the existing ExplorePi repo at the matching paths
   (adjust the relative `../../../../lib/...` imports if your repo's
   `lib/` sits elsewhere).
2. `npm install pg pi-sdk-js` (or `pnpm add` / `yarn add`) in `website/`.
3. `psql $DATABASE_URL -f db/schema.sql` then `psql $DATABASE_URL -f db/seed.sql`
   for local/dev data.
4. Copy `.env.example` to `.env.local`, fill in `PI_API_KEY` and `DATABASE_URL`.
5. `pip install psycopg2-binary stellar-sdk` if you run `reconcile_payments.py`.

## Payment flow

1. `PaymentForm` calls `authenticatePiUser()` → Pi SDK `authenticate()`.
2. `POST /api/payments` inserts a `created` row.
3. `createPiPayment()` opens the native Pi payment sheet.
4. `onReadyForServerApproval` → `POST /api/payments/[id] {action:"approve"}`
   → `approvePayment()` calls Pi Platform `/approve`, row → `submitted`.
5. `onReadyForServerCompletion` → `POST /api/payments/[id] {action:"complete", txid}`
   → `completePayment()` verifies tolerance, row → `completed` (or `failed`).
6. Pi Platform webhooks hit `/api/payments/webhook`, deduped via
   `fn_webhook_claim` so retried deliveries are no-ops.
7. `reconcile_payments.py` runs on a schedule to double-check completed
   payments against the Stellar ledger.

## Notes

- GitHub's automated-access check blocked fetching the existing
  `Tsukimarf-patch-2` branch contents directly, and the unauthenticated
  GitHub API hit its rate limit during this session — so this module was
  rebuilt from the documented createPaymen/ pattern (claims + payments +
  webhook_events, piSDK.js/piPayment.js split, tolerance + status-transition
  matrix) rather than diffed against the live branch. Worth a quick diff
  against the actual branch before merging.
