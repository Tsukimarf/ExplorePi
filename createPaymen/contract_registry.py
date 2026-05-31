import os, psycopg2

DB_DSN = os.getenv("DATABASE_URL", "postgresql://localhost/explorepi")

def register_contract(contract_id: str, label: str, network="pi-mainnet"):
    conn = psycopg2.connect(DB_DSN)
    cur  = conn.cursor()
    cur.execute("""
        INSERT INTO contracts (contract_id, label, network)
        VALUES (%s, %s, %s)
        ON CONFLICT (contract_id) DO UPDATE
          SET label = EXCLUDED.label
    """, (contract_id, label, network))
    conn.commit()
    cur.close(); conn.close()
    print(f"Registered: {contract_id} [{label}]")

def list_contracts():
    conn = psycopg2.connect(DB_DSN)
    cur  = conn.cursor()
    cur.execute("SELECT contract_id, label, network, registered_at FROM contracts ORDER BY registered_at")
    for row in cur.fetchall():
        print(row)
    cur.close(); conn.close()

# Usage:
# register_contract("CABC...XYZ", "ExplorePi Claim Contract")
# list_contracts()
