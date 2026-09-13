# Pi blockchain explorer — database schema

A reference database schema for a Pi/Stellar-style block explorer, covering ledgers (blocks), transactions, operations, accounts, assets, and balances.

## Files

| File | Description |
|---|---|
| `schema.sql` | Postgres `CREATE TABLE` statements, with foreign keys and indexes. |
| `schema.json` | Same structure as plain JSON, plus one sample record per table. |
| `models.py` | SQLAlchemy ORM models with relationships. Runnable against SQLite for local testing. |

## Entities

- **ledgers** — one row per closed ledger (block): sequence number, hash, previous hash, close time, tx count.
- **accounts** — Pi network accounts: id, sequence number, subentry count, creation time.
- **transactions** — one row per transaction: hash, parent ledger, source account, fee, memo, result code.
- **operations** — individual actions inside a transaction (payments, trustline changes, etc.), stored with a flexible `details` JSON blob.
- **assets** — asset codes and issuers (e.g. native `PI`, or issued tokens).
- **balances** — how much of each asset each account holds.

## Relationships

- A ledger contains many transactions.
- A transaction contains many operations.
- An account can submit many transactions and be the source of many operations.
- An account holds balances in one or more assets.

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

## Notes

This schema is a reasonable default modeled on typical Stellar-based block explorers — it is **not** pulled directly from the ExplorePi repository's actual code, since I wasn't able to fetch that page directly. If you have the real table definitions from the project, share them and I can update these files to match exactly.
