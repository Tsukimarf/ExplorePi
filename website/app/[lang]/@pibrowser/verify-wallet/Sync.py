#!/usr/bin/env python3
"""
sync_translations.py

Syncs website/dictionaries/*.json into the MySQL i18n schema
(languages / translation_namespaces / translations) defined in
sql/explorepi_i18n_schema.sql.

Only rows whose value actually changed get a version bump (content_hash
comparison), so re-running this is idempotent and cheap.

Usage:
    python3 sync_translations.py --dictionaries-dir website/dictionaries
    python3 sync_translations.py --dry-run

Env vars (same convention as the rest of ExplorePi's Python tooling):
    MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE
"""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Dict, Iterable, Tuple

try:
    import mysql.connector
    from mysql.connector import Error as MySQLError
except ImportError:
    print("Missing dependency: pip install mysql-connector-python", file=sys.stderr)
    sys.exit(1)


def get_connection():
    return mysql.connector.connect(
        host=os.environ.get("MYSQL_HOST", "localhost"),
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        user=os.environ.get("MYSQL_USER"),
        password=os.environ.get("MYSQL_PASSWORD"),
        database=os.environ.get("MYSQL_DATABASE"),
    )


def content_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def iter_dictionary_files(directory: Path) -> Iterable[Tuple[str, Path]]:
    """Yields (lang_code, path) for every website/dictionaries/<lang>.json file."""
    for path in sorted(directory.glob("*.json")):
        yield path.stem, path


def load_entries(directory: Path) -> Iterable[Tuple[str, str, str, str]]:
    """Yields (lang_code, namespace, key, value) flattened out of every JSON file."""
    for lang_code, path in iter_dictionary_files(directory):
        with path.open("r", encoding="utf-8") as f:
            data: Dict[str, Dict[str, str]] = json.load(f)
        for namespace, kv in data.items():
            for key, value in kv.items():
                yield lang_code, namespace, key, value


def ensure_namespace(cursor, slug: str) -> int:
    cursor.execute(
        "INSERT INTO translation_namespaces (slug) VALUES (%s) "
        "ON DUPLICATE KEY UPDATE slug = slug",
        (slug,),
    )
    cursor.execute("SELECT id FROM translation_namespaces WHERE slug = %s", (slug,))
    return cursor.fetchone()[0]


def upsert_translation(cursor, namespace_id: int, lang_code: str, key: str, value: str, dry_run: bool) -> str:
    new_hash = content_hash(value)
    cursor.execute(
        "SELECT content_hash, version FROM translations "
        "WHERE namespace_id = %s AND lang_code = %s AND translation_key = %s",
        (namespace_id, lang_code, key),
    )
    row = cursor.fetchone()

    if row is None:
        if not dry_run:
            cursor.execute(
                "INSERT INTO translations "
                "(namespace_id, lang_code, translation_key, value, content_hash, version, updated_by) "
                "VALUES (%s, %s, %s, %s, %s, 1, %s)",
                (namespace_id, lang_code, key, value, new_hash, "sync_translations.py"),
            )
        return "inserted"

    existing_hash, _version = row
    if existing_hash == new_hash:
        return "unchanged"

    if not dry_run:
        cursor.execute(
            "UPDATE translations "
            "SET value = %s, content_hash = %s, version = version + 1, updated_by = %s "
            "WHERE namespace_id = %s AND lang_code = %s AND translation_key = %s",
            (value, new_hash, "sync_translations.py", namespace_id, lang_code, key),
        )
    return "updated"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dictionaries-dir",
        default="website/dictionaries",
        help="Directory containing <lang>.json dictionary files",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would change without writing to the database",
    )
    args = parser.parse_args()

    directory = Path(args.dictionaries_dir)
    if not directory.is_dir():
        print(f"Dictionaries directory not found: {directory}", file=sys.stderr)
        sys.exit(1)

    stats = {"inserted": 0, "updated": 0, "unchanged": 0}
    namespace_cache: Dict[str, int] = {}

    try:
        conn = get_connection()
    except MySQLError as exc:
        print(f"Could not connect to MySQL: {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        cursor = conn.cursor()
        for lang_code, namespace, key, value in load_entries(directory):
            if namespace not in namespace_cache:
                namespace_cache[namespace] = ensure_namespace(cursor, namespace)
            namespace_id = namespace_cache[namespace]

            result = upsert_translation(cursor, namespace_id, lang_code, key, value, args.dry_run)
            stats[result] += 1

        if not args.dry_run:
            conn.commit()
        else:
            conn.rollback()

    finally:
        cursor.close()
        conn.close()

    mode = "DRY RUN — " if args.dry_run else ""
    print(f"{mode}inserted={stats['inserted']} updated={stats['updated']} unchanged={stats['unchanged']}")


if __name__ == "__main__":
    main()
