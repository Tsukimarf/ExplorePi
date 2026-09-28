"""Lapisan database: simpan/baca data terenkripsi post-quantum.

pip install asyncpg liboqs-python cryptography
"""
import os, hmac, hashlib
import asyncpg
from .crypto import encrypt_field, decrypt_field  # dari langkah sebelumnya

BLIND_KEY = os.environ["BLIND_INDEX_KEY"].encode()
_pool: asyncpg.Pool | None = None


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], min_size=1, max_size=10)
    return _pool


def blind_index(value: str) -> bytes:
    """HMAC deterministik supaya bisa cari exact-match tanpa mendekripsi."""
    return hmac.new(BLIND_KEY, value.lower().encode(), hashlib.sha256).digest()


async def create_account(username: str, lang: str = "en") -> str:
    pool = await get_pool()
    row = await pool.fetchrow(
        "INSERT INTO accounts (username, lang) VALUES ($1, $2) RETURNING id",
        username, lang,
    )
    await pool.execute(
        "INSERT INTO account_profiles (account_id) VALUES ($1)", row["id"]
    )
    return str(row["id"])


async def save_secret(account_id: str, field: str, value: str) -> None:
    pool = await get_pool()
    key = await pool.fetchrow(
        "SELECT id, public_key FROM pq_keys "
        "WHERE account_id = $1 AND status = 'active' ORDER BY version DESC LIMIT 1",
        account_id,
    )
    if key is None:
        raise LookupError("Belum ada kunci PQ aktif untuk akun ini")

    blob = encrypt_field(bytes(key["public_key"]), value.encode())
    await pool.execute(
        """
        INSERT INTO account_secrets
          (account_id, pq_key_id, field_name, kem_ct, nonce, data, blind_index)
        VALUES ($1,$2,$3,$4,$5,$6,$7)
        ON CONFLICT (account_id, field_name) DO UPDATE
          SET pq_key_id = EXCLUDED.pq_key_id, kem_ct = EXCLUDED.kem_ct,
              nonce = EXCLUDED.nonce, data = EXCLUDED.data,
              blind_index = EXCLUDED.blind_index
        """,
        account_id, key["id"], field,
        blob["kem"], blob["nonce"], blob["data"], blind_index(value),
    )


async def read_secret(account_id: str, field: str, secret_key: bytes) -> str | None:
    """secret_key diambil dari KMS/Vault oleh pemanggil, bukan dari database."""
    pool = await get_pool()
    row = await pool.fetchrow(
        "SELECT kem_ct, nonce, data FROM account_secrets "
        "WHERE account_id = $1 AND field_name = $2",
        account_id, field,
    )
    if row is None:
        return None
    blob = {"kem": bytes(row["kem_ct"]), "nonce": bytes(row["nonce"]), "data": bytes(row["data"])}
    return decrypt_field(secret_key, blob).decode()


async def find_account_by_secret(field: str, value: str) -> str | None:
    pool = await get_pool()
    row = await pool.fetchrow(
        "SELECT account_id FROM account_secrets WHERE field_name = $1 AND blind_index = $2",
        field, blind_index(value),
    )
    return str(row["account_id"]) if row else None


async def create_key(account_id: str, public_key: bytes, kms_ref: str, algorithm: str) -> int:
    """Buat kunci baru; kunci aktif sebelumnya ditandai 'rotated'."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            version = await conn.fetchval(
                "SELECT COALESCE(MAX(version), 0) + 1 FROM pq_keys WHERE account_id = $1",
                account_id,
            )
            await conn.execute(
                "UPDATE pq_keys SET status = 'rotated' WHERE account_id = $1 AND status = 'active'",
                account_id,
            )
            await conn.execute(
                "INSERT INTO pq_keys (account_id, algorithm, version, public_key, kms_ref) "
                "VALUES ($1,$2,$3,$4,$5)",
                account_id, algorithm, version, public_key, kms_ref,
            )
    return version


async def secret_key_ref(account_id: str, field: str) -> str | None:
    pool = await get_pool()
    return await pool.fetchval(
        "SELECT k.kms_ref FROM account_secrets s JOIN pq_keys k ON k.id = s.pq_key_id "
        "WHERE s.account_id = $1 AND s.field_name = $2",
        account_id, field,
    )
