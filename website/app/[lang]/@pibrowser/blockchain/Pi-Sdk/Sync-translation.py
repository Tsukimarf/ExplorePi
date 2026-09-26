#!/usr/bin/env python3
"""
sync_translations.py — @pibrowser/blockchain

Syncs the bundled JSON fallback dictionaries (database/locales/*.json) into
MySQL for the 'blockchain' namespace, using content-hash versioning so only
changed keys are written. Mirrors ExplorePi's existing
sync_translations.py pattern for the i18n layer.

Usage:
    python3 sync_translations.py --dsn mysql://user:pass@host:3306/explorepi
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from urllib.parse import urlparse

try:
    import mysql.connector
except ImportError:  # pragma: no cover
    print("Missing dependency: pip install mysql-connector-python", file=sys.stderr)
    raise

NAMESPACE = "blockchain"
LOCALES_DIR = Path(__file__).parent / "locales"


def sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def parse_dsn(dsn: str) -> dict:
    u = urlparse(dsn)
    return {
        "host": u.hostname or "localhost",
        "port": u.port or 3306,
        "user": u.username or "explorepi",
        "password": u.password or "",
        "database": (u.path or "/explorepi").lstrip("/"),
    }


def load_locale_files() -> dict[str, dict]:
    dictionaries = {}
    for file in sorted(LOCALES_DIR.glob("*.json")):
        lang = file.stem
        with open(file, encoding="utf-8") as f:
            dictionaries[lang] = json.load(f)
    return dictionaries


def sync(conn, dictionaries: dict[str, dict]) -> tuple[int, int]:
    cur = conn.cursor()
    cur.execute(
        "INSERT IGNORE INTO translation_namespaces (namespace) VALUES (%s)", (NAMESPACE,)
    )

    written, skipped = 0, 0
    for lang, kv in dictionaries.items():
        cur.execute(
            "INSERT IGNORE INTO languages (code, name_native) VALUES (%s, %s)",
            (lang, lang),
        )
        for key_path, value in kv.items():
            content_hash = sha256(value)
            cur.execute(
                """
                SELECT content_hash FROM translations
                WHERE namespace = %s AND lang_code = %s AND key_path = %s
                """,
                (NAMESPACE, lang, key_path),
            )
            row = cur.fetchone()
            if row and row[0] == content_hash:
                skipped += 1
                continue
            cur.execute(
                """
                INSERT INTO translations (namespace, lang_code, key_path, value, content_hash)
                VALUES (%s, %s, %s, %s, %s)
                ON DUPLICATE KEY UPDATE value = VALUES(value), content_hash = VALUES(content_hash)
                """,
                (NAMESPACE, lang, key_path, value, content_hash),
            )
            written += 1
    conn.commit()
    return written, skipped


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dsn",
        default=os.environ.get("EXPLOREPI_MYSQL_DSN", "mysql://explorepi:@localhost:3306/explorepi"),
        help="mysql://user:pass@host:port/dbname",
    )
    args = parser.parse_args()

    dictionaries = load_locale_files()
    if not dictionaries:
        print(f"No locale files found in {LOCALES_DIR}", file=sys.stderr)
        sys.exit(1)

    conn = mysql.connector.connect(**parse_dsn(args.dsn))
    try:
        written, skipped = sync(conn, dictionaries)
        print(f"[blockchain i18n] {len(dictionaries)} locales — {written} written, {skipped} unchanged")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
