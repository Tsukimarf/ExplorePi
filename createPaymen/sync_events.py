import os, time, base64, json, logging
from stellar_sdk import SorobanServer, scval
from stellar_sdk.soroban_rpc import EventFilter, EventFilterType
import psycopg2, psycopg2.extras

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("sync")

# ── Config ──────────────────────────────────────────────
RPC_URL      = os.getenv("PI_RPC_URL", "https://api.mainnet.minepi.com/soroban/rpc")
DB_DSN       = os.getenv("DATABASE_URL", "postgresql://localhost/explorepi")
CONTRACT_ID  = os.getenv("CONTRACT_ID")          # C... address
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", 6))  # seconds (1 ledger ≈ 5-6s)

# Dynamic chunk sizing (pola dari sync_payments.py sebelumnya)
CHUNK_INITIAL = int(os.getenv("CHUNK_INITIAL", 1000))
CHUNK_MIN     = int(os.getenv("CHUNK_MIN",     50))
CHUNK_MAX     = int(os.getenv("CHUNK_MAX",     5000))

# ── Soroban RPC & DB ─────────────────────────────────────
server = SorobanServer(RPC_URL)

def get_db():
    return psycopg2.connect(DB_DSN)

def get_last_ledger(cur, contract_id: str) -> int:
    cur.execute("SELECT last_ledger FROM sync_state WHERE contract_id = %s", (contract_id,))
    row = cur.fetchone()
    if row:
        return row[0]
    # fallback: 7 hari ke belakang
    latest = server.get_latest_ledger().sequence
    return max(0, latest - int(3600 / 6 * 24 * 7))

def upsert_cursor(cur, contract_id: str, ledger: int):
    cur.execute("""
        INSERT INTO sync_state (contract_id, last_ledger, updated_at)
        VALUES (%s, %s, NOW())
        ON CONFLICT (contract_id) DO UPDATE
          SET last_ledger = EXCLUDED.last_ledger,
              updated_at  = NOW()
    """, (contract_id, ledger))

def decode_scval(raw_b64: str):
    """Decode Soroban ScVal base64 → Python native."""
    try:
        xdr = base64.b64decode(raw_b64)
        val = scval.from_xdr(raw_b64)
        return scval.scval_to_native(val)
    except Exception:
        return raw_b64   # fallback raw

def parse_event(ev) -> dict:
    topics = [decode_scval(t) for t in ev.topic]
    value  = decode_scval(ev.value.xdr) if ev.value else None
    event_type = str(topics[0]) if topics else "unknown"
    return {
        "contract_id": ev.contract_id,
        "ledger":      ev.ledger,
        "txhash":      ev.id.split("-")[0] if ev.id else None,
        "event_type":  event_type,
        "topics":      json.dumps(topics),
        "value":       json.dumps(value),
    }

def insert_events(cur, events: list[dict]):
    if not events:
        return
    psycopg2.extras.execute_values(cur, """
        INSERT INTO contract_events
          (contract_id, ledger, txhash, event_type, topics, value)
        VALUES %s
        ON CONFLICT (txhash, ledger, event_type) DO NOTHING
    """, [(
        e["contract_id"], e["ledger"], e["txhash"],
        e["event_type"],  e["topics"], e["value"]
    ) for e in events])

def handle_claim_event(cur, ev: dict):
    """Parse claim event → insert into claims table."""
    try:
        topics = json.loads(ev["topics"])
        value  = json.loads(ev["value"]) if ev["value"] else {}
        cur.execute("""
            INSERT INTO claims (contract_id, user_uid, wallet_addr, amount, txid, ledger)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (txid) DO NOTHING
        """, (
            ev["contract_id"],
            topics[1] if len(topics) > 1 else None,   # user uid
            topics[2] if len(topics) > 2 else None,   # wallet address
            value.get("amount"),
            ev["txhash"],
            ev["ledger"],
        ))
    except Exception as e:
        log.warning(f"claim parse error: {e}")

# ── Main sync loop ───────────────────────────────────────
def sync_contract(contract_id: str):
    chunk = CHUNK_INITIAL
    conn  = get_db()
    cur   = conn.cursor()

    start_ledger = get_last_ledger(cur, contract_id)
    latest       = server.get_latest_ledger().sequence
    log.info(f"Starting sync {contract_id} ledger {start_ledger} → {latest}")

    while True:
        latest = server.get_latest_ledger().sequence
        if start_ledger >= latest:
            time.sleep(POLL_INTERVAL)
            continue

        end_ledger = min(start_ledger + chunk, latest)
        try:
            res = server.get_events(
                start_ledger,
                filters=[EventFilter(
                    type=EventFilterType.CONTRACT,
                    contract_ids=[contract_id],
                )]
            )
            events = [parse_event(e) for e in res.events]
            insert_events(cur, events)

            # Route claim events
            for ev in events:
                if ev["event_type"] in ("claim", "reward"):
                    handle_claim_event(cur, ev)

            upsert_cursor(cur, contract_id, end_ledger)
            conn.commit()

            if events:
                log.info(f"Ledger {start_ledger}→{end_ledger}: {len(events)} events ingested")

            # Grow chunk on success
            chunk = min(int(chunk * 1.5), CHUNK_MAX)
            start_ledger = end_ledger

        except Exception as e:
            conn.rollback()
            log.error(f"RPC error: {e} — halving chunk {chunk}→{chunk//2}")
            chunk = max(chunk // 2, CHUNK_MIN)
            time.sleep(POLL_INTERVAL * 2)

if __name__ == "__main__":
    assert CONTRACT_ID, "Set CONTRACT_ID env var (C... address)"
    sync_contract(CONTRACT_ID)
