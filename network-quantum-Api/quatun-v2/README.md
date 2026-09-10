# network-quantum-api v2.0.0

ExplorePi — Pi Network account profile & metadata API.  
Stack: **Node.js · Express · MySQL · stellar-sdk (Soroban/Horizon)**

---

## Setup

```bash
npm install
cp .env.example .env   # fill in your values
mysql -u root -p < ../schema.sql
npm start
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `PORT` | Server port (default 3000) |
| `DB_HOST / DB_USER / DB_PASSWORD / DB_NAME` | MySQL connection |
| `PI_CONTRACT_ADDRESS` | Soroban contract address (starts with `C`) |
| `PI_HORIZON_URL` | Pi Horizon endpoint |
| `PI_NETWORK_PASSPHRASE` | `Pi Network Mainnet` |
| `API_SECRET` | Auth header value for `x-api-key` |

---

## Authentication

Pass `x-api-key: <API_SECRET>` in every request header.

---

## Endpoints

### Health
```
GET /health
```

### Contract
```
GET /api/contract?address=CXXX
```
Resolves Soroban contract metadata from Pi Network.

---

### Accounts

#### Register / upsert account
```
POST /api/accounts/register
Body: { wallet_address, contract_address? }
```

#### Get full account + profile + metadata
```
GET /api/accounts/:wallet
```

#### Update profile
```
PUT /api/accounts/:wallet/profile
Body: {
  username, display_name, bio,
  avatar_url, website_url,
  twitter_handle, github_handle,
  language, timezone
}
```

#### Set metadata key-value
```
PUT /api/accounts/:wallet/metadata
Body: { key, value }
```

#### Get all metadata
```
GET /api/accounts/:wallet/metadata
```

#### Sync on-chain data → DB
```
POST /api/accounts/:wallet/sync
```
Pulls account data entries and Pi balance from Horizon into `account_metadata` table.

---

## Database Tables

| Table | Purpose |
|---|---|
| `accounts` | wallet + contract address |
| `account_profiles` | username, bio, social links, language, timezone |
| `account_metadata` | arbitrary key-value (app or chain source) |
| `audit_log` | action history with IP |
