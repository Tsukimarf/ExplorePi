# ExplorePi Payment System — Recommended Rules Matrix

Branch: `Tsukimarf-patch-1` · Covers: `explorepi_payment_update.sql`, `explorepi_payment_partial_update.sql`, `explorepi_payment_tolerance_update.sql`, `explorepi_webhook_events_schema.sql`, `webhookProcessor.js`

This is the single reference for the rules the system already enforces (or should) across the payment lifecycle. Table 1 and Table 2 are implemented in `explorepi_rules_matrix_update.sql` (enforced in the database). Tables 3 and 4 are operational policy — apply them in `webhookProcessor.js` / on-call runbooks.

---

## 1. Payment Status Transition Matrix

Which `payment_status` transitions are legal. Anything marked ✗ should raise an exception rather than silently succeed — this is now enforced by a `BEFORE UPDATE` trigger reading the `payment_status_transitions` table, replacing the ad-hoc `WHERE status IN (...)` guards spread across the `fn_payment_mark_*` functions.

| From \ To              | created | pending_approval | approved | pending_completion | partially_paid | completed | cancelled | error |
|-------------------------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **created**              | –   | ✓   | ✓   | ✗   | ✗   | ✗   | ✓   | ✓   |
| **pending_approval**     | ✗   | –   | ✓   | ✗   | ✗   | ✗   | ✓   | ✓   |
| **approved**             | ✗   | ✗   | –   | ✓   | ✓   | ✓   | ✓   | ✓   |
| **pending_completion**   | ✗   | ✗   | ✗   | –   | ✓   | ✓   | ✓   | ✓   |
| **partially_paid**       | ✗   | ✗   | ✗   | ✗   | –   | ✓   | ✗¹  | ✓   |
| **completed**            | ✗   | ✗   | ✗   | ✗   | ✗   | –   | ✗   | ✗   |
| **cancelled**            | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | –   | ✗   |
| **error**                | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✓²  | –   |

¹ A partially paid payment should not be cancelled outright — funds already landed. Route to refund instead of a status flip.
² Reopening from `error` back to `cancelled` is allowed for the case where an error turns out unrecoverable and needs formal closure; `error → completed`/`approved`/etc. is not, since the failure needs a fresh payment, not a resurrected one.

`completed`, `cancelled` are terminal from the state machine's perspective — no outbound transitions.

---

## 2. Dynamic Tolerance Tiers (recommended, per network)

Replaces the flat per-network `pct_rate`/`min_floor`/`max_cap` in `payment_tolerance_config` with amount-banded tiers — a 0.05 Pi tip and a 500 Pi payout shouldn't use the same percentage.

### `pi-mainnet`

| Amount band (Pi) | min_floor | pct_rate | max_cap  | Rationale |
|---|---|---|---|---|
| 0.0000001 – 1.00   | 0.0000500 | 0.500% | 0.0050000 | Flat network fee dominates; floor does the work, not the percentage. |
| 1.00 – 10.00       | 0.0001000 | 0.100% | 0.0100000 | Current default tier (see `explorepi_payment_tolerance_update.sql`). |
| 10.00 – 100.00     | 0.0010000 | 0.050% | 0.0500000 | Percentage narrows as absolute amounts grow. |
| 100.00 +           | 0.0100000 | 0.020% | 0.2000000 | Cap prevents the percentage term from becoming a meaningful discount. |

### `pi-testnet`

| Amount band (Pi) | min_floor | pct_rate | max_cap  |
|---|---|---|---|
| any               | 0.0001000 | 0.200% | 0.0500000 |

Testnet stays a single loose band — no need to protect against real-value discrepancies there.

---

## 3. Webhook Event Handling Matrix

Retry/alerting policy per `event.type`, for `webhookProcessor.js`'s dynamic dispatcher. `max_retries` here overrides the global default (`5`) passed to `fn_webhook_claim`.

| event.type          | Criticality | max_retries | Alert on exhaustion | Notes |
|---|---|---|---|---|
| `payment.approval`     | High     | 8  | Page on-call        | Blocks the entire payment; user is mid-flow in the Pi Wallet UI. |
| `payment.completion`   | Critical | 10 | Page on-call         | Failure here means funds moved on-chain but the DB doesn't know it. Prioritize `horizon.payment` reconciliation as a backstop. |
| `payment.partial`      | High     | 8  | Page on-call         | Same class as completion — an installment already landed on-chain. |
| `horizon.payment`      | Medium   | 5  | Slack notify          | Reconciliation backstop for the above two; not the only path to `completed`. |
| `payment.cancelled`    | Low      | 3  | Log only              | No funds at risk; worst case is a stale `pending_completion` row. |
| `payment.error`        | Low      | 3  | Log only              | Already represents a known failure; retries just re-record the same outcome. |
| *(unregistered type)*  | —        | —  | Log only (`unhandled`)| Not an error — new event types should show up here first, then get a handler added. |

---

## 4. Escalation Rules

What happens after retries are exhausted (`webhook_events.status = 'failed' AND retry_count >= max_retries`), or when a DB-level guard rejects an operation.

| Trigger | Action | Owner |
|---|---|---|
| Webhook retries exhausted, Critical/High event | Page on-call; manually replay via `fn_webhook_mark_result(event_id, 'received')` after root cause is fixed | Backend on-call |
| Webhook retries exhausted, Low event | Weekly triage query against dead-letter set (`webhook_events WHERE status='failed' AND retry_count>=max_retries`) | Backend team, async |
| `trg_apply_installment_totals` raises overpay-beyond-tolerance | Do **not** retry the insert. Route to a manual refund/credit workflow — the extra funds are real and need a decision, not a retry. | Payments/finance |
| `payment_status_transitions` trigger rejects a transition | Treat as a bug, not a retry target — an illegal transition means the caller's state assumption is wrong. Log and investigate the caller. | Backend on-call |
| A `partially_paid` payment stalls (no installment for > 24h) | Scheduled job flags it for manual follow-up (chase the remaining installment or issue a partial refund) | Backend team, async |

---

## Change log

| Rule set | Source of truth | Enforced by |
|---|---|---|
| §1 Status transitions | `payment_status_transitions` table | `trg_enforce_status_transition` (BEFORE UPDATE on `payments`) |
| §2 Tolerance tiers | `payment_tolerance_tiers` table | `fn_calculate_tolerance()` (tier lookup replaces flat per-network rate) |
| §3 Webhook retry policy | `webhook_retry_policy` table | `fn_webhook_claim()` (`max_retries` param sourced from policy, not hardcoded) |
| §4 Escalation | Operational runbook (this doc) | On-call / async triage — not database-enforced |

See `explorepi_rules_matrix_update.sql` for the schema and enforcement changes backing §1–§3.
