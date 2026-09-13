"""
ExplorePi - Python Crawler (replaces crawler/index.js)
Fetches Pi blockchain data from the Horizon API and stores it via database.py
"""

import os
import time
import json
import logging
import requests
from datetime import datetime
from database import (
    init_schema, upsert_block, upsert_transaction,
    upsert_account, upsert_operation, get_latest_block
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

HORIZON_URL = os.getenv("HORIZON_URL", "https://api.mainnet.minepi.com")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL_SEC", 5))


# ─────────────────────────────────────────────
# Horizon API helpers
# ─────────────────────────────────────────────

def horizon_get(path: str, params: dict = None) -> dict:
    url = f"{HORIZON_URL}{path}"
    resp = requests.get(url, params=params, timeout=15)
    resp.raise_for_status()
    return resp.json()


def fetch_ledgers(cursor: str = "now", order: str = "desc", limit: int = 20) -> list:
    data = horizon_get("/ledgers", {"cursor": cursor, "order": order, "limit": limit})
    return data.get("_embedded", {}).get("records", [])


def fetch_transactions(ledger_seq: int, limit: int = 200) -> list:
    data = horizon_get(f"/ledgers/{ledger_seq}/transactions", {"limit": limit})
    return data.get("_embedded", {}).get("records", [])


def fetch_operations(tx_id: str, limit: int = 50) -> list:
    data = horizon_get(f"/transactions/{tx_id}/operations", {"limit": limit})
    return data.get("_embedded", {}).get("records", [])


def fetch_account(address: str) -> dict:
    return horizon_get(f"/accounts/{address}")


# ─────────────────────────────────────────────
# Parsers
# ─────────────────────────────────────────────

def parse_block(rec: dict) -> dict:
    return {
        "id":           rec["sequence"],
        "hash":         rec["hash"],
        "prev_hash":    rec.get("prev_hash"),
        "ledger_seq":   rec["sequence"],
        "closed_at":    datetime.fromisoformat(rec["closed_at"].replace("Z", "")),
        "tx_count":     rec.get("transaction_count", 0),
        "base_fee":     rec.get("base_fee_in_stroops", 0),
        "base_reserve": rec.get("base_reserve_in_stroops", 0),
        "total_coins":  float(rec.get("total_coins", 0)),
        "fee_pool":     float(rec.get("fee_pool", 0)),
    }


def parse_transaction(rec: dict, ledger_seq: int) -> dict:
    return {
        "id":              rec["id"],
        "ledger_seq":      ledger_seq,
        "account":         rec["source_account"],
        "fee_charged":     rec.get("fee_charged", 0),
        "operation_count": rec.get("operation_count", 0),
        "tx_type":         rec.get("envelope_xdr", "")[:20],
        "result_code":     rec.get("result_code"),
        "created_at":      datetime.fromisoformat(rec["created_at"].replace("Z", "")),
    }


def parse_operation(rec: dict, tx_id: str) -> dict:
    details = {k: v for k, v in rec.items()
               if k not in ("id", "type", "type_i", "source_account", "created_at")}
    return {
        "id":             int(rec["id"]),
        "tx_id":          tx_id,
        "op_type":        rec.get("type_i", 0),
        "op_type_name":   rec.get("type"),
        "source_account": rec.get("source_account"),
        "created_at":     datetime.fromisoformat(rec["created_at"].replace("Z", "")),
        "details":        json.dumps(details),
    }


def parse_account(rec: dict) -> dict:
    return {
        "address":        rec["account_id"],
        "balance":        next(
            (float(b["balance"]) for b in rec.get("balances", [])
             if b["asset_type"] == "native"), 0.0
        ),
        "sequence":       int(rec.get("sequence", 0)),
        "subentry_count": rec.get("subentry_count", 0),
        "last_modified":  rec.get("last_modified_ledger"),
        "home_domain":    rec.get("home_domain", ""),
    }


# ─────────────────────────────────────────────
# Crawl logic
# ─────────────────────────────────────────────

def crawl_ledger(seq: int):
    logger.info(f"  Crawling ledger {seq}…")
    # transactions
    for tx_rec in fetch_transactions(seq):
        tx = parse_transaction(tx_rec, seq)
        upsert_transaction(tx)
        # operations
        for op_rec in fetch_operations(tx_rec["id"]):
            upsert_operation(parse_operation(op_rec, tx_rec["id"]))
        # account snapshot for source
        try:
            acc_raw = fetch_account(tx_rec["source_account"])
            upsert_account(parse_account(acc_raw))
        except Exception:
            pass


def crawl_loop():
    init_schema()
    logger.info("ExplorePi Python crawler started.")

    latest = get_latest_block()
    cursor = str(latest["ledger_seq"]) if latest else "now"

    while True:
        try:
            ledgers = fetch_ledgers(cursor=cursor, order="asc", limit=10)
            if not ledgers:
                logger.info("No new ledgers. Waiting…")
                time.sleep(POLL_INTERVAL)
                continue

            for ledger in ledgers:
                block = parse_block(ledger)
                upsert_block(block)
                crawl_ledger(block["ledger_seq"])
                cursor = str(block["ledger_seq"])
                logger.info(f"✓ Ledger {block['ledger_seq']} — {block['tx_count']} txs")

        except requests.RequestException as e:
            logger.error(f"Network error: {e}. Retrying in {POLL_INTERVAL}s…")
            time.sleep(POLL_INTERVAL)
        except Exception as e:
            logger.exception(f"Unexpected error: {e}")
            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    crawl_loop()
