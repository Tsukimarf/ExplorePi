# Pi blockchain explorer — database schema

A reference database schema for a Pi/Stellar-style block explorer, covering ledgers (blocks), transactions, operations, accounts, assets, and balances.

## Files

| File | Language | Description |
|---|---|---|
| `schema.sql` | SQL | Postgres `CREATE TABLE` statements, with foreign keys and indexes. |
| `schema.JSON` | JSON | Same structure as plain JSON, plus one sample record per table. |
| `models.py` | Python | SQLAlchemy models; run directly to create a local SQLite DB for testing. |
| `models.js` | JavaScript | Sequelize models for a Postgres-backed API layer. |

## Entities

- **ledgers** — one row per closed ledger (block): sequence number, hash, previous hash, close time, tx count.
- **accounts** — Pi network accounts: id, sequence number, subentry count, creation time.
- **transactions** — one row per transaction: hash, parent ledger, source account, fee, memo, result code.
- **operations** — individual actions inside a transaction (payments, trustline changes, etc.), stored with a flexible `details` JSON blob.
- **assets** — asset codes and issuers (e.g. native `PI`, or issued tokens).
- **balances** — how much of each asset each account holds.
- **payments** — the payment subset of operations (`type_i = 1`), denormalized by `from_account`/`to_account` for fast lookups. Field names (`from`, `to`, `amount`, `created_at`, `type_i`) match what [`explorer/payment.jsx`](../explorer/payment.jsx) reads off each Horizon payment record.

## Relationships

- A ledger contains many transactions.
- A transaction contains many operations.
- An account can submit many transactions and be the source of many operations.
- An account holds balances in one or more assets.
- A transaction (via its payment operations) has many payments; each payment has a sender and a receiver account.

## Getting started

**Postgres**

```bash
psql -d your_database -f schema.sql
```

**Python / SQLAlchemy**

```bash
pip install sqlalchemy
python models.py   # creates pi_explorer.db (SQLite) for local testing
```

**JavaScript / Sequelize**

```bash
npm install sequelize pg pg-hstore
```
```js
const { Sequelize } = require('sequelize')
const initModels = require('./models')
const db = initModels(new Sequelize(process.env.DATABASE_URL))
await db.sequelize.sync()
```

## Notes

`explorer/payment.jsx` currently reads payments **live from Horizon** (`server.payments()`) rather than from a local database — it needs no schema at all to keep working. The `payments` table/model here exists for a future local index (e.g. an ingestion worker that writes Horizon payment streams into Postgres), and its fields intentionally match the shape that component already expects, so an API route backed by these models can return the same JSON without any frontend changes.

This schema is a reasonable default modeled on typical Stellar-based block explorers — the ledgers/accounts/transactions/operations/assets/balances tables are **not** pulled directly from a live copy of ExplorePi's own backend (I don't have access to that). The `payments` table and model files above, however, are grounded directly in `explorer/payment.jsx`'s actual field usage. If you have the real backend table definitions, share them and I can reconcile these files exactly.
