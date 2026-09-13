# ExplorePi — Python Crawler & Data Mining

Converted from the original Node.js stack to **Python 3.10+**, with a new
**Matematika China** data-mining module.

## File Structure

```
explorePi_python/
├── crawler.py       # Main crawler (replaces crawler/index.js)
├── database.py      # DB layer (replaces Web3 JS database calls)
├── mining.py        # Chinese Mathematics data mining
├── requirements.txt
└── .env.example
```

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env   # fill in your DB credentials
python crawler.py      # starts the crawler
```

## Environment Variables

| Variable          | Default                         | Description              |
|-------------------|---------------------------------|--------------------------|
| `DB_HOST`         | `localhost`                     | MySQL host               |
| `DB_PORT`         | `3306`                          | MySQL port               |
| `DB_USER`         | `explorepi`                     | MySQL user               |
| `DB_PASSWORD`     | *(empty)*                       | MySQL password           |
| `DB_NAME`         | `explorepi`                     | MySQL database name      |
| `HORIZON_URL`     | `https://api.mainnet.minepi.com`| Pi Network Horizon node  |
| `POLL_INTERVAL_SEC` | `5`                           | Seconds between polls    |

## Data Mining: Matematika China (mining.py)

Five classical Chinese mathematical methods applied to blockchain analytics:

### 1. 余数定理 — Chinese Remainder Theorem
Shards blockchain addresses across N database partitions using CRT-based
modular arithmetic for load-balanced storage.

```python
from mining import crt_shard_index, shard_address_distribution
idx = crt_shard_index("GXXXXXX...", num_shards=8)  # → 0..7
```

### 2. 河图洛书 — Lo Shu Magic Square
Maps the last 9 blocks onto a 3×3 magic square to detect transaction
activity balance. A score near 1.0 means even distribution.

```python
from mining import block_magic_score
result = block_magic_score(blocks)
# → {"balance_score": 0.87, "interpretation": "balanced", ...}
```

### 3. 正态分布 — Normal Distribution Outliers
Z-score outlier detection on transaction fees and account balances to
identify abnormal activity and whale accounts.

```python
from mining import fee_outliers, balance_outliers
print(fee_outliers(z_threshold=2.5))
print(balance_outliers(z_threshold=3.0))
```

### 4. 算术级数 — Arithmetic Progression Trend
Fits a linear (arithmetic progression) model to block transaction counts,
returning the common difference `d` and R² fit quality.

```python
from mining import ledger_growth_trend
trend = ledger_growth_trend(limit=100)
# → {"trend": "growing", "common_difference_d": 0.042, "r_squared": 0.91}
```

### 5. 筹算 — Rod Calculus Cumulative Sums
Computes running cumulative fee totals and expanding moving averages
across blocks, inspired by ancient Chinese rod-calculus abacus methods.

```python
from mining import cumulative_fee_totals, block_tx_running_average
```

### Full Report

```python
from mining import full_mining_report
import json
print(json.dumps(full_mining_report(), indent=2, default=str))
```

## What Changed from Node.js

| Before (JS)                        | After (Python)                  |
|------------------------------------|---------------------------------|
| `mysql2/promise` pool              | `mysql-connector-python` pool   |
| `async/await` with `.then()`       | Synchronous with connection pool|
| `index.js` Horizon fetch loop      | `crawler.py` with `requests`    |
| No analytics                       | `mining.py` — 5 math modules    |
| `database.sql` schema only         | `init_schema()` auto-creates DB |
