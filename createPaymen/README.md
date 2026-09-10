# ExplorePi

> A Raspberry Pi project-sharing platform with Pi Network blockchain integration — claim rewards, send Pi, and sync on-chain events to a database.

[![Pi Network](https://img.shields.io/badge/Pi%20Network-Mainnet-7C3AED?style=flat-square)](https://minepi.com)
[![Soroban](https://img.shields.io/badge/Soroban-v23%20WASM-00B2FF?style=flat-square)](https://stellar.org/soroban)
[![Python](https://img.shields.io/badge/Python-3.11%2B-3776AB?style=flat-square)](https://python.org)
[![Node.js](https://img.shields.io/badge/Node.js-20%2B-339933?style=flat-square)](https://nodejs.org)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](./LICENSE)

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Pi Network SDK Integration](#pi-network-sdk-integration)
- [Smart Contract (Soroban)](#smart-contract-soroban)
- [Database Schema](#database-schema)
- [Event Sync](#event-sync)
- [API Reference](#api-reference)
- [Running the Project](#running-the-project)
- [Docker / Container](#docker--container)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

**ExplorePi** is an open-source web platform for sharing and discovering Raspberry Pi projects. In addition to the project browser and multi-language IDE, this branch (`Tsukimarf-patch-1`) adds:

- **Pi Network blockchain integration** — authenticate users via Pi SDK, claim daily Pi rewards, and send Pi directly from the app.
- **Soroban smart contract** (Rust/WASM, Protocol v23) — on-chain subscription and claim logic running on the Pi Mainnet / Stellar Soroban VM.
- **Contract-to-database sync** — Python indexer listens to Soroban `ContractEvents` and writes them to PostgreSQL in real time.
- **Browser-based multi-language IDE** — supports HTML, Python, JavaScript, JSON, C++20, and SQL via CodeMirror.

---

## Features

| Feature | Status |
|---|---|
| Pi Network Auth (`pi.connect()`) | ✅ |
| Daily Claim (A2U payment) | ✅ |
| Send Pi to any address | ✅ |
| Transaction history & status checker | ✅ |
| Soroban claim contract (Rust/WASM) | ✅ |
| Contract event sync → PostgreSQL | ✅ |
| Multi-contract address registry | ✅ |
| Multi-language browser IDE | ✅ |
| Docker Compose (app + DB + indexer) | ✅ |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     Browser (Frontend)                    │
│  pi-sdk-js (ESM)  ·  React/HTML UI  ·  CodeMirror IDE   │
└─────────────┬────────────────────────┬────────────────────┘
              │ Pi.connect()           │ REST API
              ▼                        ▼
┌─────────────────────┐    ┌───────────────────────────────┐
│   Pi Browser / App  │    │       Express Backend          │
│  (Pi Network Wallet)│    │  pi-backend  ·  Node.js 20+   │
└─────────────────────┘    │  /approve  /complete  /claim  │
                           └──────────────┬────────────────┘
                                          │
              ┌───────────────────────────┼────────────────┐
              ▼                           ▼                 ▼
┌─────────────────────┐   ┌──────────────────┐  ┌──────────────────┐
│ Pi Mainnet Soroban  │   │   PostgreSQL DB   │  │  sync_events.py  │
│ RPC (Protocol v23)  │◄──│  contracts        │◄─│  Soroban RPC     │
│ Rust/WASM Contract  │   │  contract_events  │  │  getEvents()     │
│ C... address        │   │  claims           │  │  stellar-sdk     │
└─────────────────────┘   │  sync_state       │  └──────────────────┘
                           └──────────────────┘
```

---

## Prerequisites

| Dependency | Version | Notes |
|---|---|---|
| Node.js | 20+ | ESM support required |
| Python | 3.11+ | For event indexer |
| PostgreSQL | 15+ | Main database |
| Rust + Cargo | stable | For Soroban contract build |
| Soroban CLI | 22.0.0+ | `cargo install soroban-cli` |
| Pi Developer Account | — | [developer.minepi.com](https://developer.minepi.com) |
| Pi API Key | — | From Pi Developer Portal |

---

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/Tsukimarf/ExplorePi.git
cd ExplorePi
git checkout Tsukimarf-patch-1
```

### 2. Install frontend + backend dependencies

```bash
# Backend
npm install

# Frontend (if separate workspace)
cd client && npm install && cd ..
```

### 3. Install Python indexer dependencies

```bash
pip install stellar-sdk psycopg2-binary python-dotenv --break-system-packages
```

### 4. Initialize the database

```bash
psql -U postgres -d explorepi -f schema.sql
```

### 5. Build the Soroban contract (optional — use pre-deployed address)

```bash
cd contracts/claim
cargo build --target wasm32-unknown-unknown --release
soroban contract deploy \
  --wasm target/wasm32-unknown-unknown/release/claim.wasm \
  --network pi-mainnet \
  --source YOUR_SECRET_KEY
```

---

## Configuration

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

### `.env`

```env
# ── Pi Network ─────────────────────────────────────────
PI_API_KEY=your_pi_api_key_here
PI_WALLET_PRIVATE_SEED=S...          # starts with S (Stellar keypair)
PI_RPC_URL=https://api.mainnet.minepi.com/soroban/rpc
PI_HORIZON_URL=https://api.mainnet.minepi.com

# ── Smart Contract ──────────────────────────────────────
CONTRACT_ID=C...                     # deployed Soroban contract address

# ── Database ────────────────────────────────────────────
DATABASE_URL=postgresql://user:pass@localhost:5432/explorepi

# ── Event Indexer ───────────────────────────────────────
CHUNK_INITIAL=1000
CHUNK_MIN=50
CHUNK_MAX=5000
POLL_INTERVAL=6                      # seconds (1 ledger ≈ 5–6s on Pi Mainnet)

# ── App ─────────────────────────────────────────────────
PORT=3000
NODE_ENV=production
```

---

## Pi Network SDK Integration

This project uses **`pi-sdk-js`** (ESM, TypeScript) and **`pi-backend`** (Node.js) — the official Pi Network SDK stack as of 2026.

### Install

```bash
npm install pi-sdk-js pi-backend
```

### Frontend — Authentication

```js
// src/pi/auth.js
import { PiSdkBase } from 'pi-sdk-js'

const pi = new PiSdkBase()

export async function connectPi() {
  await pi.connect()
  return pi.user  // { name, uid, ... }
}
```

> **Breaking change from older SDK:** `Pi.authenticate(scopes, callback)` is replaced by `pi.connect()`. Import via ESM only — no CDN script tag.

### Frontend — Create Payment (U2A)

```js
export function createPayment({ amount, memo, metadata, onApproval, onComplete, onCancel, onError }) {
  return pi.createPayment(
    { amount, memo, metadata },
    {
      onReadyForServerApproval: (paymentId) => onApproval(paymentId),
      onReadyForServerCompletion: (paymentId, txid) => onComplete(paymentId, txid),
      onCancel:  (paymentId) => onCancel(paymentId),
      onError:   (error, payment) => onError(error, payment),
    }
  )
}
```

### Backend — Approve & Complete

```js
// src/pi/payments.js
import PiNetwork from 'pi-backend'

const pi = new PiNetwork(process.env.PI_API_KEY, process.env.PI_WALLET_PRIVATE_SEED)

export const approvePayment  = (paymentId) => pi.approvePayment(paymentId)
export const completePayment = (paymentId, txid) => pi.completePayment(paymentId, txid)
```

### Backend — App-to-User Reward (Claim)

```js
export async function rewardUser(userUid, amount, memo, productId) {
  const paymentId = await pi.createPayment({
    amount,
    memo,
    metadata: { productId },
    uid: userUid,
  })
  const txid = await pi.submitPayment(paymentId)
  await pi.completePayment(paymentId, txid)
  return { paymentId, txid }
}
```

### Claim flow (end-to-end)

```
User clicks "Claim"
  → pi.connect()                        [auth / KYC check]
  → POST /api/approve  { paymentId }    [server approves]
  → Pi Wallet modal opens               [user signs]
  → POST /api/complete { paymentId, txid } [server submits]
  → INSERT INTO claims                  [record to DB]
  → Response: { success: true, txid }
```

---

## Smart Contract (Soroban)

### Protocol

Pi Network Protocol v23 (activated Pi Day 2026) — Rust/WASM contracts on the Soroban VM, identical architecture to Stellar Soroban.

### Contract address

```
C...  (set CONTRACT_ID in .env)
```

### Key entry points

```rust
// contracts/claim/src/lib.rs

#[contractimpl]
impl ClaimContract {
    /// Initialize contract with admin and daily reward amount
    pub fn initialize(env: Env, admin: Address, daily_amount: i128) { ... }

    /// User claims daily reward — emits ContractEvent "claim"
    pub fn claim(env: Env, user: Address) -> i128 { ... }

    /// Admin sets new daily amount
    pub fn set_daily_amount(env: Env, admin: Address, amount: i128) { ... }
}
```

### Events emitted

| Event type | Topics | Value |
|---|---|---|
| `claim` | `["claim", user_uid, wallet_addr]` | `{ amount: i128 }` |
| `transfer` | `["transfer", from, to]` | `{ amount: i128 }` |
| `subscribe` | `["subscribe", user_uid]` | `{ plan: Symbol, expires: u64 }` |

### Build & deploy

```bash
cd contracts/claim
cargo build --target wasm32-unknown-unknown --release

soroban contract deploy \
  --wasm target/wasm32-unknown-unknown/release/claim.wasm \
  --network pi-mainnet \
  --source YOUR_SECRET_KEY

# Initialize
soroban contract invoke \
  --id $CONTRACT_ID \
  --network pi-mainnet \
  -- initialize \
  --admin YOUR_ADMIN_ADDRESS \
  --daily_amount 3141500  # 3.1415 Pi (7 decimal places)
```

---

## Database Schema

```sql
-- Contract registry (multi-contract support)
CREATE TABLE contracts (
  id            SERIAL PRIMARY KEY,
  contract_id   VARCHAR(56) NOT NULL UNIQUE,   -- C... Soroban address
  label         VARCHAR(100),
  network       VARCHAR(20) DEFAULT 'pi-mainnet',
  registered_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sync cursor per contract
CREATE TABLE sync_state (
  contract_id   VARCHAR(56) PRIMARY KEY REFERENCES contracts(contract_id),
  last_ledger   BIGINT NOT NULL DEFAULT 0,
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Raw contract events (all types)
CREATE TABLE contract_events (
  id            SERIAL PRIMARY KEY,
  contract_id   VARCHAR(56) NOT NULL,
  ledger        BIGINT NOT NULL,
  txhash        VARCHAR(128),
  event_type    VARCHAR(50),
  topics        JSONB,
  value         JSONB,
  ingested_at   TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(txhash, ledger, event_type)
);

-- Parsed claim records
CREATE TABLE claims (
  id            SERIAL PRIMARY KEY,
  contract_id   VARCHAR(56),
  user_uid      VARCHAR(128),
  wallet_addr   VARCHAR(56),
  amount        NUMERIC(18,7),
  payment_id    VARCHAR(128),
  txid          VARCHAR(128) UNIQUE,
  ledger        BIGINT,
  claimed_at    TIMESTAMPTZ DEFAULT NOW()
);
```

---

## Event Sync

The indexer (`sync_events.py`) polls the Soroban RPC `getEvents` endpoint, decodes XDR ScVal topics/values, and writes to PostgreSQL. It uses cursor-based ledger tracking with dynamic chunk sizing — the same pattern as `sync_payments.py` for EVM chains.

### Run indexer

```bash
# Single contract
CONTRACT_ID=C... python sync_events.py

# Or with Docker (see below)
docker compose up indexer
```

### Dynamic chunk sizing

| Condition | Action |
|---|---|
| RPC success | `chunk = min(chunk × 1.5, CHUNK_MAX)` |
| RPC error / timeout | `chunk = max(chunk ÷ 2, CHUNK_MIN)` |
| Up to date | sleep `POLL_INTERVAL` seconds |

### Register a new contract

```python
from contract_registry import register_contract

register_contract(
    contract_id="CABC...XYZ",
    label="ExplorePi Claim Contract",
    network="pi-mainnet"
)
```

---

## API Reference

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/pi/approve` | Approve Pi payment (server-side) |
| `POST` | `/api/pi/complete` | Complete Pi payment, submit txid |
| `POST` | `/api/claim` | Trigger A2U reward to user |
| `GET`  | `/api/tx/:txid` | Get transaction status |
| `GET`  | `/api/claims/:uid` | Get claim history for user |
| `GET`  | `/api/contracts` | List registered contracts |

### `POST /api/claim`

```json
// Request
{ "userUid": "abc123", "projectId": "rpi-weather-station" }

// Response
{ "success": true, "txid": "0xA3F1...9C2B", "amount": 3.1415 }

// Error (already claimed)
{ "error": "Already claimed today" }
```

---

## Running the Project

### Development

```bash
# Start backend
npm run dev

# Start event indexer (separate terminal)
python sync_events.py

# Start frontend dev server (if separate)
cd client && npm run dev
```

### Production

```bash
npm run build
npm start
```

---

## Docker / Container

```bash
# Build and run everything
docker compose up --build

# Scale indexer independently
docker compose up --scale indexer=1
```

### `docker-compose.yml`

```yaml
version: '3.9'
services:
  app:
    build: .
    ports: ["3000:3000"]
    env_file: .env
    depends_on: [db]

  indexer:
    build:
      context: .
      dockerfile: Dockerfile.indexer
    env_file: .env
    depends_on: [db]
    restart: unless-stopped

  db:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: explorepi
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./schema.sql:/docker-entrypoint-initdb.d/schema.sql

volumes:
  pgdata:
```

### `Dockerfile.indexer`

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt --break-system-packages
COPY sync_events.py contract_registry.py ./
CMD ["python", "sync_events.py"]
```

### `requirements.txt`

```
stellar-sdk>=11.0.0
psycopg2-binary>=2.9.9
python-dotenv>=1.0.0
```

---

## Contributing

1. Fork the repo and create a feature branch off `main`.
2. Follow existing code style (ESLint for JS, `rustfmt` for Rust, `black` for Python).
3. Add or update tests for new functionality.
4. Open a PR with a clear description — one concern per PR.
5. Reference any related GitHub Issues in your PR description.

### Branch naming

```
feat/short-description
fix/issue-title
chore/dependency-update
```

---

## License

This project is licensed under the **MIT License** — see [LICENSE](./LICENSE) for full terms.

© 2026
