"""
ExplorePi - Data Mining: Matematika China (Chinese Mathematics Methods)
Applies classical Chinese mathematical algorithms to Pi blockchain analytics.

Methods implemented:
  - 余数定理 (Chinese Remainder Theorem) — hash/address sharding
  - 河图洛书 (Hetu Luoshu / Magic Squares) — block pattern detection
  - 正态分布 (Normal Distribution) — fee & balance outlier detection
  - 算术级数 (Arithmetic Progressions) — ledger growth analysis
  - 筹算 (Rod Calculus inspired) — running totals / cumulative sums
"""

import math
from functools import reduce
from typing import Optional
from database import (
    get_blocks, get_transactions, get_rich_list,
    _fetchall, _fetchone
)


# ══════════════════════════════════════════════════════════════════
# 1. 余数定理  Chinese Remainder Theorem — address / hash sharding
# ══════════════════════════════════════════════════════════════════

def crt_shard_index(address: str, num_shards: int = 8) -> int:
    """
    Assign a Pi blockchain address to a data shard using CRT-inspired
    modular arithmetic. Maps an address to shard 0..num_shards-1.
    """
    # Convert address bytes to integer via product of prime residues
    primes = [3, 5, 7, 11, 13, 17, 19, 23][:num_shards]
    residues = [ord(c) % p for c, p in zip(address[:num_shards], primes)]

    # Solve: find x ≡ residues[i] (mod primes[i]) for all i
    M = reduce(lambda a, b: a * b, primes)
    x = 0
    for r, p in zip(residues, primes):
        Mi = M // p
        inv = pow(Mi, -1, p)  # modular inverse (Python 3.8+)
        x += r * Mi * inv
    return (x % M) % num_shards


def shard_address_distribution(addresses: list[str], num_shards: int = 8) -> dict:
    """Return count of addresses per shard."""
    dist = {i: 0 for i in range(num_shards)}
    for addr in addresses:
        dist[crt_shard_index(addr, num_shards)] += 1
    return dist


# ══════════════════════════════════════════════════════════════════
# 2. 河图洛书  Magic Square Block Pattern Detector
# ══════════════════════════════════════════════════════════════════

def _luoshu_3x3() -> list[list[int]]:
    """Classical 3×3 Lo Shu magic square (all lines sum to 15)."""
    return [
        [2, 7, 6],
        [9, 5, 1],
        [4, 3, 8],
    ]


def block_magic_score(blocks: list[dict]) -> dict:
    """
    Map the last 9 block tx_counts onto the Lo Shu 3×3 grid and compute
    row/column/diagonal balance scores. A balanced blockchain has equal
    activity distribution — score closer to 1.0 is more balanced.
    """
    counts = [b["tx_count"] for b in blocks[-9:]]
    if len(counts) < 9:
        return {"error": "Need at least 9 blocks", "score": None}

    grid = _luoshu_3x3()
    total = sum(counts) or 1
    weighted = [counts[i] * grid[i // 3][i % 3] for i in range(9)]

    row_sums = [sum(weighted[r*3:(r+1)*3]) for r in range(3)]
    col_sums = [sum(weighted[c::3]) for c in range(3)]
    diag1 = weighted[0] + weighted[4] + weighted[8]
    diag2 = weighted[2] + weighted[4] + weighted[6]

    all_sums = row_sums + col_sums + [diag1, diag2]
    mean = sum(all_sums) / len(all_sums)
    variance = sum((s - mean) ** 2 for s in all_sums) / len(all_sums)
    cv = math.sqrt(variance) / mean if mean else 0

    return {
        "block_ids": [b["ledger_seq"] for b in blocks[-9:]],
        "tx_counts": counts,
        "row_sums": row_sums,
        "col_sums": col_sums,
        "diagonals": [diag1, diag2],
        "balance_score": round(max(0.0, 1.0 - cv), 4),
        "interpretation": "balanced" if cv < 0.15 else ("moderate" if cv < 0.4 else "skewed"),
    }


# ══════════════════════════════════════════════════════════════════
# 3. 正态分布  Outlier Detection (fee & balance)
# ══════════════════════════════════════════════════════════════════

def _mean_std(values: list[float]) -> tuple[float, float]:
    if not values:
        return 0.0, 0.0
    mu = sum(values) / len(values)
    variance = sum((v - mu) ** 2 for v in values) / len(values)
    return mu, math.sqrt(variance)


def fee_outliers(limit: int = 500, z_threshold: float = 2.5) -> dict:
    """
    Find transactions with abnormally high fees using z-score.
    Z > z_threshold flags the tx as an outlier.
    """
    txs = _fetchall(
        "SELECT id, account, fee_charged, created_at FROM transactions "
        "ORDER BY created_at DESC LIMIT %s", (limit,)
    )
    fees = [float(t["fee_charged"]) for t in txs]
    mu, sigma = _mean_std(fees)
    if sigma == 0:
        return {"mean": mu, "std": sigma, "outliers": []}

    outliers = [
        {**t, "z_score": round((float(t["fee_charged"]) - mu) / sigma, 3)}
        for t in txs
        if abs(float(t["fee_charged"]) - mu) / sigma > z_threshold
    ]
    return {
        "sample_size": len(txs),
        "mean_fee": round(mu, 4),
        "std_fee": round(sigma, 4),
        "z_threshold": z_threshold,
        "outlier_count": len(outliers),
        "outliers": sorted(outliers, key=lambda x: x["z_score"], reverse=True)[:20],
    }


def balance_outliers(z_threshold: float = 3.0) -> dict:
    """Identify whale accounts using z-score on balances."""
    accounts = _fetchall("SELECT address, balance FROM accounts", ())
    balances = [float(a["balance"]) for a in accounts]
    mu, sigma = _mean_std(balances)
    if sigma == 0:
        return {"mean": mu, "std": sigma, "whales": []}

    whales = [
        {**a, "z_score": round((float(a["balance"]) - mu) / sigma, 3)}
        for a in accounts
        if (float(a["balance"]) - mu) / sigma > z_threshold
    ]
    return {
        "total_accounts": len(accounts),
        "mean_balance": round(mu, 7),
        "std_balance": round(sigma, 7),
        "whale_count": len(whales),
        "whales": sorted(whales, key=lambda x: x["z_score"], reverse=True)[:50],
    }


# ══════════════════════════════════════════════════════════════════
# 4. 算术级数  Arithmetic Progression — Ledger Growth Trend
# ══════════════════════════════════════════════════════════════════

def ledger_growth_trend(limit: int = 100) -> dict:
    """
    Fit an arithmetic progression to tx_count per block.
    Returns common difference d (trend) and R² fit quality.
    """
    rows = _fetchall(
        "SELECT ledger_seq, tx_count FROM blocks ORDER BY ledger_seq DESC LIMIT %s",
        (limit,)
    )
    rows = list(reversed(rows))  # oldest first
    if len(rows) < 2:
        return {"error": "Not enough blocks"}

    n = len(rows)
    xs = list(range(n))
    ys = [float(r["tx_count"]) for r in rows]

    # Least-squares linear fit: y = a + d*x
    sum_x = sum(xs)
    sum_y = sum(ys)
    sum_xx = sum(x * x for x in xs)
    sum_xy = sum(x * y for x, y in zip(xs, ys))
    denom = n * sum_xx - sum_x ** 2
    d = (n * sum_xy - sum_x * sum_y) / denom if denom else 0
    a = (sum_y - d * sum_x) / n

    # R²
    y_mean = sum_y / n
    ss_tot = sum((y - y_mean) ** 2 for y in ys)
    ss_res = sum((y - (a + d * x)) ** 2 for x, y in zip(xs, ys))
    r2 = 1 - ss_res / ss_tot if ss_tot else 0

    return {
        "blocks_analyzed": n,
        "first_ledger": rows[0]["ledger_seq"],
        "last_ledger": rows[-1]["ledger_seq"],
        "intercept_a": round(a, 4),
        "common_difference_d": round(d, 6),
        "trend": "growing" if d > 0.01 else ("shrinking" if d < -0.01 else "stable"),
        "r_squared": round(r2, 4),
        "predicted_next": round(a + d * n, 2),
    }


# ══════════════════════════════════════════════════════════════════
# 5. 筹算  Rod Calculus — Cumulative Sums (running totals)
# ══════════════════════════════════════════════════════════════════

def cumulative_fee_totals(limit: int = 200) -> list[dict]:
    """
    Compute running cumulative fee totals across recent transactions —
    inspired by the rod calculus (筹算) abacus-style accumulation method.
    """
    txs = _fetchall(
        "SELECT id, account, fee_charged, created_at FROM transactions "
        "ORDER BY created_at ASC LIMIT %s", (limit,)
    )
    running = 0.0
    result = []
    for tx in txs:
        running += float(tx["fee_charged"])
        result.append({
            "tx_id": tx["id"],
            "account": tx["account"],
            "fee": float(tx["fee_charged"]),
            "cumulative_fee": round(running, 4),
            "created_at": str(tx["created_at"]),
        })
    return result


def block_tx_running_average(limit: int = 50) -> list[dict]:
    """Expanding mean of tx_count per block — moving average analytics."""
    blocks = _fetchall(
        "SELECT ledger_seq, tx_count, closed_at FROM blocks "
        "ORDER BY ledger_seq ASC LIMIT %s", (limit,)
    )
    total = 0.0
    result = []
    for i, b in enumerate(blocks, 1):
        total += b["tx_count"]
        result.append({
            "ledger_seq": b["ledger_seq"],
            "tx_count": b["tx_count"],
            "running_avg": round(total / i, 4),
            "closed_at": str(b["closed_at"]),
        })
    return result


# ══════════════════════════════════════════════════════════════════
# 6. 综合报告  Full Mining Report
# ══════════════════════════════════════════════════════════════════

def full_mining_report() -> dict:
    """Run all mining algorithms and return a consolidated report."""
    print("⛏  Running Pi blockchain data mining (Matematika China)…")

    blocks = get_blocks(limit=100)
    accounts = _fetchall("SELECT address FROM accounts LIMIT 1000", ())
    addresses = [a["address"] for a in accounts]

    report = {
        "generated_at": __import__("datetime").datetime.utcnow().isoformat() + "Z",
        "crt_shard_distribution": shard_address_distribution(addresses),
        "magic_square_balance": block_magic_score(blocks),
        "fee_outliers": fee_outliers(),
        "balance_outliers": balance_outliers(),
        "ledger_growth_trend": ledger_growth_trend(),
        "cumulative_fees_last_200": cumulative_fee_totals(200)[-5:],  # last 5
        "block_running_avg_last_50": block_tx_running_average(50)[-5:],
    }
    return report


# ──────────────────────────────
# CLI
# ──────────────────────────────
if __name__ == "__main__":
    import json
    report = full_mining_report()
    print(json.dumps(report, indent=2, default=str))
