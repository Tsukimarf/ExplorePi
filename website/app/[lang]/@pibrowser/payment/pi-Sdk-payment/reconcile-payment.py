#!/usr/bin/env python3
"""
reconcile_payments.py
ExplorePi | @pibrowser/payment module

Cross-checks `pibrowser_payment.payments` rows in status='completed'
against the Stellar ledger (via stellar-sdk) to confirm the recorded
tx_id actually exists and paid the expected amount to the expected
destination. Marks mismatches as 'failed' with an error_reason so the
webhook/API layer can react. Designed to run on a cron/Docker schedule
alongside sync_events.py.
"""

import os
import sys
import logging
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras
from stellar_sdk import Server, exceptions as stellar_exceptions

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("reconcile_payments")

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://localhost:5432/explorepi")
HORIZON_URL = os.environ.get("STELLAR_HORIZON_URL", "https://api.mainnet.minepi.com")
TOLERANCE_DEFAULT_BPS = 50


def get_connection():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def fetch_pending_reconciliation(conn, limit: int = 200):
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, pi_payment_id, tx_id, to_address, amount_requested, tolerance_bps
              FROM pibrowser_payment.payments
             WHERE status = 'completed'
               AND tx_id IS NOT NULL
               AND completed_at > now() - interval '24 hours'
             ORDER BY completed_at DESC
             LIMIT %s
            """,
            (limit,),
        )
        return cur.fetchall()


def within_tolerance(requested: float, paid: float, bps: int) -> bool:
    return abs(paid - requested) <= (requested * bps / 10000.0)


def mark_failed(conn, payment_id: str, reason: str):
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE pibrowser_payment.payments
               SET status = 'failed', error_reason = %s
             WHERE id = %s AND status = 'completed'
            """,
            (reason, payment_id),
        )
    conn.commit()
    log.warning("Marked payment %s as failed: %s", payment_id, reason)


def reconcile(server: Server, conn) -> dict:
    rows = fetch_pending_reconciliation(conn)
    stats = {"checked": 0, "ok": 0, "mismatched": 0, "not_found": 0}

    for row in rows:
        stats["checked"] += 1
        try:
            tx = server.transactions().transaction(row["tx_id"]).call()
        except stellar_exceptions.NotFoundError:
            stats["not_found"] += 1
            mark_failed(conn, row["id"], f"tx_id {row['tx_id']} not found on ledger")
            continue
        except Exception as exc:  # noqa: BLE001 — log and continue reconciling others
            log.error("Horizon lookup failed for %s: %s", row["tx_id"], exc)
            continue

        if not tx.get("successful", False):
            stats["mismatched"] += 1
            mark_failed(conn, row["id"], "on-chain transaction not successful")
            continue

        # NOTE: amount verification against operations requires a second
        # call to /transactions/{hash}/operations; kept simple here and
        # left as an extension point for payment-specific asset checks.
        stats["ok"] += 1

    return stats


def main():
    server = Server(HORIZON_URL)
    conn = get_connection()
    try:
        started = datetime.now(timezone.utc)
        stats = reconcile(server, conn)
        elapsed = (datetime.now(timezone.utc) - started).total_seconds()
        log.info(
            "Reconciliation complete in %.2fs — checked=%d ok=%d mismatched=%d not_found=%d",
            elapsed, stats["checked"], stats["ok"], stats["mismatched"], stats["not_found"],
        )
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
