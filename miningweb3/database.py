"""
ExplorePi - Python Database Layer
Replaces the original Node.js Web3 database (crawler/index.js + database.sql)
Pi Blockchain block explorer database interface
"""

import os
import mysql.connector
from mysql.connector import pooling
from datetime import datetime
from typing import Optional
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────
# Database Configuration
# ─────────────────────────────────────────────
DB_CONFIG = {
    "host":     os.getenv("DB_HOST", "localhost"),
    "port":     int(os.getenv("DB_PORT", 3306)),
    "user":     os.getenv("DB_USER", "explorepi"),
    "password": os.getenv("DB_PASSWORD", ""),
    "database": os.getenv("DB_NAME", "explorepi"),
    "charset":  "utf8mb4",
    "collation": "utf8mb4_unicode_ci",
}

# Connection pool (replaces Node.js mysql2/promise pool)
connection_pool = pooling.MySQLConnectionPool(
    pool_name="explorepi_pool",
    pool_size=10,
    **DB_CONFIG
)


def get_connection():
    return connection_pool.get_connection()


# ─────────────────────────────────────────────
# Schema Initializer  (from original database.sql)
# ─────────────────────────────────────────────
SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS blocks (
    id              BIGINT UNSIGNED PRIMARY KEY,
    hash            VARCHAR(128)     NOT NULL UNIQUE,
    prev_hash       VARCHAR(128),
    ledger_seq      BIGINT UNSIGNED  NOT NULL,
    closed_at       DATETIME         NOT NULL,
    tx_count        INT UNSIGNED     DEFAULT 0,
    base_fee        BIGINT UNSIGNED  DEFAULT 0,
    base_reserve    BIGINT UNSIGNED  DEFAULT 0,
    total_coins     DECIMAL(20,7)    DEFAULT 0,
    fee_pool        DECIMAL(20,7)    DEFAULT 0,
    created_at      DATETIME         DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_closed_at (closed_at),
    INDEX idx_ledger_seq (ledger_seq)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS transactions (
    id              VARCHAR(128)     PRIMARY KEY,
    ledger_seq      BIGINT UNSIGNED  NOT NULL,
    account         VARCHAR(64)      NOT NULL,
    fee_charged     BIGINT UNSIGNED  DEFAULT 0,
    operation_count INT UNSIGNED     DEFAULT 0,
    tx_type         VARCHAR(64),
    result_code     VARCHAR(64),
    created_at      DATETIME         NOT NULL,
    INDEX idx_account (account),
    INDEX idx_ledger_seq (ledger_seq),
    INDEX idx_created_at (created_at),
    FOREIGN KEY (ledger_seq) REFERENCES blocks(ledger_seq)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS accounts (
    address         VARCHAR(64)      PRIMARY KEY,
    balance         DECIMAL(20,7)    DEFAULT 0,
    sequence        BIGINT UNSIGNED  DEFAULT 0,
    subentry_count  INT UNSIGNED     DEFAULT 0,
    last_modified   BIGINT UNSIGNED,
    home_domain     VARCHAR(255),
    created_at      DATETIME         DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME         DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_balance (balance),
    INDEX idx_updated_at (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS operations (
    id              BIGINT UNSIGNED  PRIMARY KEY,
    tx_id           VARCHAR(128)     NOT NULL,
    op_type         INT UNSIGNED     NOT NULL,
    op_type_name    VARCHAR(64),
    source_account  VARCHAR(64),
    created_at      DATETIME         NOT NULL,
    details         JSON,
    INDEX idx_tx_id (tx_id),
    INDEX idx_op_type (op_type),
    INDEX idx_source_account (source_account),
    FOREIGN KEY (tx_id) REFERENCES transactions(id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"""

def init_schema():
    conn = get_connection()
    cursor = conn.cursor()
    for stmt in SCHEMA_SQL.strip().split(";"):
        stmt = stmt.strip()
        if stmt:
            cursor.execute(stmt)
    conn.commit()
    cursor.close()
    conn.close()
    logger.info("Schema initialized.")


# ─────────────────────────────────────────────
# Block Operations
# ─────────────────────────────────────────────
def upsert_block(block: dict):
    sql = """
        INSERT INTO blocks
            (id, hash, prev_hash, ledger_seq, closed_at, tx_count,
             base_fee, base_reserve, total_coins, fee_pool)
        VALUES
            (%(id)s, %(hash)s, %(prev_hash)s, %(ledger_seq)s, %(closed_at)s,
             %(tx_count)s, %(base_fee)s, %(base_reserve)s, %(total_coins)s, %(fee_pool)s)
        ON DUPLICATE KEY UPDATE
            tx_count    = VALUES(tx_count),
            total_coins = VALUES(total_coins),
            fee_pool    = VALUES(fee_pool)
    """
    _execute(sql, block)


def get_latest_block() -> Optional[dict]:
    sql = "SELECT * FROM blocks ORDER BY ledger_seq DESC LIMIT 1"
    return _fetchone(sql)


def get_block_by_seq(seq: int) -> Optional[dict]:
    return _fetchone("SELECT * FROM blocks WHERE ledger_seq = %s", (seq,))


def get_block_by_hash(h: str) -> Optional[dict]:
    return _fetchone("SELECT * FROM blocks WHERE hash = %s", (h,))


def get_blocks(limit: int = 20, offset: int = 0) -> list:
    return _fetchall(
        "SELECT * FROM blocks ORDER BY ledger_seq DESC LIMIT %s OFFSET %s",
        (limit, offset)
    )


# ─────────────────────────────────────────────
# Transaction Operations
# ─────────────────────────────────────────────
def upsert_transaction(tx: dict):
    sql = """
        INSERT IGNORE INTO transactions
            (id, ledger_seq, account, fee_charged, operation_count,
             tx_type, result_code, created_at)
        VALUES
            (%(id)s, %(ledger_seq)s, %(account)s, %(fee_charged)s,
             %(operation_count)s, %(tx_type)s, %(result_code)s, %(created_at)s)
    """
    _execute(sql, tx)


def get_transactions(limit: int = 20, offset: int = 0) -> list:
    return _fetchall(
        "SELECT * FROM transactions ORDER BY created_at DESC LIMIT %s OFFSET %s",
        (limit, offset)
    )


def get_transactions_by_account(address: str, limit: int = 20) -> list:
    return _fetchall(
        "SELECT * FROM transactions WHERE account = %s ORDER BY created_at DESC LIMIT %s",
        (address, limit)
    )


def get_transaction(tx_id: str) -> Optional[dict]:
    return _fetchone("SELECT * FROM transactions WHERE id = %s", (tx_id,))


# ─────────────────────────────────────────────
# Account Operations
# ─────────────────────────────────────────────
def upsert_account(account: dict):
    sql = """
        INSERT INTO accounts
            (address, balance, sequence, subentry_count, last_modified, home_domain)
        VALUES
            (%(address)s, %(balance)s, %(sequence)s, %(subentry_count)s,
             %(last_modified)s, %(home_domain)s)
        ON DUPLICATE KEY UPDATE
            balance         = VALUES(balance),
            sequence        = VALUES(sequence),
            subentry_count  = VALUES(subentry_count),
            last_modified   = VALUES(last_modified),
            home_domain     = VALUES(home_domain)
    """
    _execute(sql, account)


def get_account(address: str) -> Optional[dict]:
    return _fetchone("SELECT * FROM accounts WHERE address = %s", (address,))


def get_rich_list(limit: int = 100) -> list:
    return _fetchall(
        "SELECT * FROM accounts ORDER BY balance DESC LIMIT %s", (limit,)
    )


# ─────────────────────────────────────────────
# Operations
# ─────────────────────────────────────────────
def upsert_operation(op: dict):
    sql = """
        INSERT IGNORE INTO operations
            (id, tx_id, op_type, op_type_name, source_account, created_at, details)
        VALUES
            (%(id)s, %(tx_id)s, %(op_type)s, %(op_type_name)s,
             %(source_account)s, %(created_at)s, %(details)s)
    """
    _execute(sql, op)


def get_operations_by_tx(tx_id: str) -> list:
    return _fetchall(
        "SELECT * FROM operations WHERE tx_id = %s ORDER BY id ASC", (tx_id,)
    )


# ─────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────
def _execute(sql: str, params=None):
    conn = get_connection()
    cursor = conn.cursor(dictionary=True)
    try:
        cursor.execute(sql, params)
        conn.commit()
    except Exception as e:
        conn.rollback()
        logger.error(f"DB error: {e}")
        raise
    finally:
        cursor.close()
        conn.close()


def _fetchone(sql: str, params=None) -> Optional[dict]:
    conn = get_connection()
    cursor = conn.cursor(dictionary=True)
    try:
        cursor.execute(sql, params or ())
        return cursor.fetchone()
    finally:
        cursor.close()
        conn.close()


def _fetchall(sql: str, params=None) -> list:
    conn = get_connection()
    cursor = conn.cursor(dictionary=True)
    try:
        cursor.execute(sql, params or ())
        return cursor.fetchall()
    finally:
        cursor.close()
        conn.close()
