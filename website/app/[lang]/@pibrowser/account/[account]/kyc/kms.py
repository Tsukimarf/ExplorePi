"""Penyimpanan secret key PQ.

PERINGATAN: implementasi ini berbasis file (mode 0600) hanya untuk development.
Untuk produksi ganti put()/get() dengan HashiCorp Vault, AWS KMS, atau GCP KMS.
"""
import os, uuid, pathlib

KMS_DIR = pathlib.Path(os.environ.get("KMS_DIR", "/run/kms"))


def put(secret_key: bytes) -> str:
    KMS_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    ref = uuid.uuid4().hex
    path = KMS_DIR / ref
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(secret_key)
    return ref


def get(ref: str) -> bytes:
    if not ref.isalnum():
        raise ValueError("kms_ref tidak valid")
    return (KMS_DIR / ref).read_bytes()
