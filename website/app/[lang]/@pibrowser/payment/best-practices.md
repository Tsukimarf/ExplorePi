# ExplorePi Payment System — Additional Best Practices

Branch: `Tsukimarf-patch-1` · Layers on top of the full chain:
`schema.sql → explorepi_payment_update.sql → explorepi_payment_partial_update.sql → explorepi_payment_tolerance_update.sql → explorepi_webhook_events_schema.sql → explorepi_rules_matrix_update.sql`

Everything below marked **[SQL]** is implemented in `explorepi_best_practices_update.sql` (7th file in the chain). Everything marked **[Ops]** is a runbook/process practice, not enforceable in the database.

---

## 1. Least-privilege database roles **[SQL]**

The app currently connects with one superuser-adjacent role for everything — schema owner, app writes, and any future read-only reporting all share one credential. Split into three:

| Role | Access | Used by |
|---|---|---|
| `explorepi_owner` | Full DDL — the role that ran files 1–7 | Migrations only, never a running service |
| `explorepi_app` | `SELECT/INSERT/UPDATE` on payment tables, `EXECUTE` on `fn_*` functions, **no** `DELETE`, **no** DDL | `webhookProcessor.js`, `piPayment.js`, API backend |
| `explorepi_readonly` | `SELECT` only, and only on the `v_*` views — no direct table access | Dashboards, BI tools, on-call read-only debugging |

No service credential should be able to `DROP TABLE payments` or `DELETE FROM payments` — deletions, if ever needed, go through an explicit archival function (see §3), not ad-hoc `DELETE`.

## 2. Observability views **[SQL]**

Three views for dashboards/alerting, so "is the payment system healthy" is a query, not a manual join every time:

- `v_payment_health_metrics` — completion rate, average `created_at → completed_at` duration, count currently stuck in `partially_paid`/`pending_completion`, all over a rolling 24h window
- `v_stuck_payments` — payments sitting in a non-terminal state longer than expected (feeds the "partially_paid stalls > 24h" escalation rule from the rules matrix)
- `v_webhook_health` — processed/failed/unhandled counts per event type over 24h, for the retry-policy alert thresholds to act on

## 3. Data retention & archival, not deletion **[SQL]**

`webhook_events` and `payment_status_history` are append-only audit logs — they grow forever by design, but "forever" in the live table hurts query performance over time. Archive, don't delete:

- `payments_archive` / `webhook_events_archive` — same shape, no FKs constraining them
- `fn_archive_completed_payments(older_than)` — moves `completed`/`cancelled` payments (and their installments/history) older than a cutoff into the archive tables, in a single transaction per batch
- Nothing is ever hard-deleted; the archive tables are the "cold storage" tier a compliance/audit request can still query

## 4. Idempotent creation **[SQL]**

`fn_payment_create` currently raises a unique-violation if called twice with the same `payment_id` (e.g. a retried API request before the first insert's response reached the client). Add `fn_payment_get_or_create` — same signature, but `ON CONFLICT (payment_id) DO NOTHING` then returns the existing row, so retries of payment creation are as safe as webhook retries already are.

## 5. Additional integrity constraints **[SQL]**

- `wallet_addr` / `contract_id` format checks (`G...`/`C...`, correct length) at the table level, not just application-side — a malformed address should never reach the row
- `memo` length capped to Stellar's 28-byte text-memo limit where the payment is expected to produce an on-chain memo, with a comment explaining why (prevents a valid-looking payment from failing at broadcast time)

## 6. Query performance **[SQL]**

- Composite index `(status, network, created_at)` on `payments` — the health views and stuck-payment queries all filter by status first
- Partial index on `webhook_events` for `status = 'failed'` only — the dead-letter query is the hot path on that table, and a partial index keeps it small regardless of total table size

## 7. Operational practices **[Ops — not enforced in SQL]**

- **Connection pooling**: `webhookProcessor.js`'s `pg.Pool` should set explicit `max` (e.g. 10–20) and `idleTimeoutMillis` — an unbounded pool under webhook burst traffic can exhaust the DB's `max_connections` alongside the main API pool.
- **Secrets**: `PI_WEBHOOK_SECRET`, `PI_API_KEY`, `PI_WALLET_PRIVATE_SEED`, `DATABASE_URL` belong in a secrets manager (not `.env` in production) — `.env` is fine for local dev only, matching the existing `.env.example` pattern in `createPaymen/`.
- **Migrations**: apply files 1–7 through a migration tool (e.g. `node-pg-migrate`, `sqitch`) rather than manual `psql -f` in production, so the applied order is tracked and repeatable.
- **Backups**: standard PostgreSQL PITR (`pg_basebackup` + WAL archiving) covers this schema with no special handling required — nothing here uses unlogged tables or anything that would need a different backup strategy.
- **Testing the rules matrix**: before deploying changes to `payment_status_transitions` or `payment_tolerance_tiers`, run the assertion queries in `explorepi_best_practices_update.sql`'s footer against a staging DB — they exercise every legal/illegal transition and a tolerance boundary case per tier.
