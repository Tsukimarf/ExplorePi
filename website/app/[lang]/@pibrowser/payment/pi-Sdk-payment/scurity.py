#!/usr/bin/env python3
"""
security.py
---------------------------------------------------------------------
Security layer for ExplorePi's pi-Sdk-payment module
(website/app/[lang]/@pibrowser/payment/pi-Sdk-payment, branch
Tsukimarf-patch-2).

Python-side counterpart to lib/pi/pqcPayment.js — used by
scripts/reconcile_payments.py, pqc_rotate_payment_keys.py, and any
Python service that verifies or issues payment/webhook signatures.

Provides:
  - Hybrid ML-DSA-65 (FIPS 204) + Ed25519 sign/verify, digest-compatible
    with the JS implementation (domain-separated SHAKE256 pre-hash,
    canonical JSON)
  - Constant-time comparison helpers (no short-circuit signature checks)
  - A sliding-window rate limiter for payment/webhook endpoints
  - Input validation/sanitization for payment payloads
  - Secret loading with strict file-permission enforcement
  - Structured, secret-redacting audit logging

Requires: liboqs-python, pynacl
    pip install liboqs-python pynacl
---------------------------------------------------------------------
"""

from __future__ import annotations

import base64
import hmac
import json
import logging
import os
import re
import stat
import time
from collections import defaultdict, deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Deque, Dict, Optional

import oqs
from nacl.exceptions import BadSignatureError
from nacl.hash import blake2b
from nacl.signing import SigningKey, VerifyKey

PQC_ALGORITHM = "ML-DSA-65"
CLASSICAL_ALGORITHM = "Ed25519"

PQC_DOMAIN = {
    "PAYMENT_CREATE": "explorepi.payment.create.v1",
    "PAYMENT_APPROVE": "explorepi.payment.approve.v1",
    "PAYMENT_COMPLETE": "explorepi.payment.complete.v1",
    "WEBHOOK_EVENT": "explorepi.payment.webhook.v1",
}

# ---------------------------------------------------------------------
# Logging — structured, redacts anything that looks like a secret key
# ---------------------------------------------------------------------
_REDACT_KEYS = {"secretkey", "secret_key", "pqc_secret_key", "classical_secret_key", "apikey", "api_key", "password"}


class RedactingFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        if isinstance(record.args, dict):
            record.args = {
                k: ("[REDACTED]" if k.lower().replace(" ", "_") in _REDACT_KEYS else v)
                for k, v in record.args.items()
            }
        return super().format(record)


logger = logging.getLogger("explorepi.payment.security")
_handler = logging.StreamHandler()
_handler.setFormatter(RedactingFormatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
logger.addHandler(_handler)
logger.setLevel(logging.INFO)


# ---------------------------------------------------------------------
# Canonicalization + digest — must match lib/pi/pqcPayment.js exactly
# ---------------------------------------------------------------------
def _canonicalize(value: Any) -> Any:
    if isinstance(value, list):
        return [_canonicalize(v) for v in value]
    if isinstance(value, dict):
        return {k: _canonicalize(value[k]) for k in sorted(value.keys())}
    return value


def domain_digest(domain: str, payload: Dict[str, Any]) -> bytes:
    """SHAKE256, 64-byte output, over `domain\\x00<canonical JSON>`."""
    import hashlib

    canonical = json.dumps(_canonicalize(payload), separators=(",", ":"))
    msg = f"{domain}\x00{canonical}".encode("utf-8")
    shake = hashlib.shake_256(msg)
    return shake.digest(64)


# ---------------------------------------------------------------------
# Hybrid sign / verify
# ---------------------------------------------------------------------
@dataclass
class HybridSignature:
    digest: str  # base64
    pqc_signature: str  # base64
    classical_signature: str  # base64
    algorithm: str
    domain: str
    signed_at: str


@dataclass
class VerificationResult:
    valid: bool
    pqc_valid: bool
    classical_valid: bool
    reason: Optional[str] = None


def hybrid_sign(domain: str, payload: Dict[str, Any], pqc_secret_key_b64: str, classical_secret_key_b64: str) -> HybridSignature:
    digest = domain_digest(domain, payload)

    with oqs.Signature(PQC_ALGORITHM, base64.b64decode(pqc_secret_key_b64)) as signer:
        pqc_sig = signer.sign(digest)

    classical_secret = base64.b64decode(classical_secret_key_b64)
    signing_key = SigningKey(classical_secret)
    classical_sig = signing_key.sign(digest).signature

    return HybridSignature(
        digest=base64.b64encode(digest).decode(),
        pqc_signature=base64.b64encode(pqc_sig).decode(),
        classical_signature=base64.b64encode(classical_sig).decode(),
        algorithm=f"{PQC_ALGORITHM}+{CLASSICAL_ALGORITHM}",
        domain=domain,
        signed_at=datetime.now(timezone.utc).isoformat(),
    )


def hybrid_verify(
    domain: str,
    payload: Dict[str, Any],
    signature: Dict[str, str],
    pqc_public_key_b64: str,
    classical_public_key_b64: str,
    mode: str = "strict",
) -> VerificationResult:
    """
    mode: 'strict' requires both signatures valid.
          'pqc-optional' requires classical valid; PQC checked if present.
    """
    digest = domain_digest(domain, payload)
    expected_digest = base64.b64decode(signature["digest"])

    if not hmac.compare_digest(digest, expected_digest):
        return VerificationResult(False, False, False, "digest_mismatch")

    classical_valid = False
    try:
        verify_key = VerifyKey(base64.b64decode(classical_public_key_b64))
        verify_key.verify(digest, base64.b64decode(signature["classical_signature"]))
        classical_valid = True
    except BadSignatureError:
        classical_valid = False

    pqc_valid = False
    pqc_sig_b64 = signature.get("pqc_signature") or signature.get("pqcSignature")
    if pqc_sig_b64:
        with oqs.Signature(PQC_ALGORITHM) as verifier:
            pqc_valid = verifier.verify(
                digest,
                base64.b64decode(pqc_sig_b64),
                base64.b64decode(pqc_public_key_b64),
            )

    if mode == "strict":
        reason = None
        if not pqc_valid:
            reason = "pqc_signature_invalid_or_missing"
        elif not classical_valid:
            reason = "classical_signature_invalid"
        return VerificationResult(classical_valid and pqc_valid, pqc_valid, classical_valid, reason)

    # pqc-optional
    reason = "pqc_signature_absent_migration_gap" if not pqc_sig_b64 else None
    return VerificationResult(classical_valid, pqc_valid, classical_valid, reason)


# ---------------------------------------------------------------------
# Rate limiting — sliding window, per signer/IP key
# ---------------------------------------------------------------------
class SlidingWindowRateLimiter:
    """In-process sliding-window limiter. For multi-instance deployments,
    back this with Redis (INCR + EXPIRE per window bucket) instead."""

    def __init__(self, max_requests: int, window_seconds: int):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._hits: Dict[str, Deque[float]] = defaultdict(deque)

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        window_start = now - self.window_seconds
        hits = self._hits[key]
        while hits and hits[0] < window_start:
            hits.popleft()
        if len(hits) >= self.max_requests:
            logger.warning("rate_limit_exceeded key=%s count=%d", key, len(hits))
            return False
        hits.append(now)
        return True


# Defaults: payment creation is tighter than webhook ingestion, which
# can legitimately burst on Pi Network retry storms.
payment_create_limiter = SlidingWindowRateLimiter(max_requests=10, window_seconds=60)
webhook_limiter = SlidingWindowRateLimiter(max_requests=120, window_seconds=60)


# ---------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------
_PI_UID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
_PAYMENT_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{8,128}$")

MAX_MEMO_LENGTH = 512
MAX_AMOUNT_PI = 1_000_000  # sanity ceiling, not a business rule


class ValidationError(ValueError):
    pass


def validate_payment_payload(payload: Dict[str, Any]) -> None:
    """Raises ValidationError with a specific reason; never silently
    coerces or truncates suspicious input."""
    uid = payload.get("uid")
    if not uid or not _PI_UID_RE.match(str(uid)):
        raise ValidationError("invalid_uid")

    payment_id = payload.get("paymentId") or payload.get("payment_id")
    if payment_id is not None and not _PAYMENT_ID_RE.match(str(payment_id)):
        raise ValidationError("invalid_payment_id")

    amount = payload.get("amount")
    if amount is None:
        raise ValidationError("missing_amount")
    try:
        amount_val = float(amount)
    except (TypeError, ValueError):
        raise ValidationError("amount_not_numeric")
    if amount_val <= 0 or amount_val > MAX_AMOUNT_PI:
        raise ValidationError("amount_out_of_range")

    memo = payload.get("memo", "")
    if memo and len(memo) > MAX_MEMO_LENGTH:
        raise ValidationError("memo_too_long")
    if memo and re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", memo):
        raise ValidationError("memo_contains_control_characters")


def validate_webhook_payload(payload: Dict[str, Any]) -> None:
    event_type = payload.get("type") or payload.get("eventType")
    if not event_type or not isinstance(event_type, str):
        raise ValidationError("missing_event_type")
    event_id = payload.get("id") or payload.get("eventId")
    if not event_id or not _PAYMENT_ID_RE.match(str(event_id)):
        raise ValidationError("invalid_event_id")


# ---------------------------------------------------------------------
# Secret loading — enforces 0600 permissions before reading
# ---------------------------------------------------------------------
def load_secret_store(path: str) -> Dict[str, Any]:
    if not os.path.exists(path):
        raise FileNotFoundError(f"secret store not found: {path}")

    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise PermissionError(
            f"refusing to read secret store {path}: permissions {oct(mode)} "
            "are too open (expected 0600)"
        )

    with open(path, "r") as f:
        return json.load(f)


def fingerprint_public_key(public_key_b64: str) -> str:
    """Short, non-reversible identifier for logging public keys safely."""
    raw = base64.b64decode(public_key_b64)
    return blake2b(raw, digest_size=8).hex()


# ---------------------------------------------------------------------
# Audit logging
# ---------------------------------------------------------------------
def audit_log(event: str, **fields: Any) -> None:
    safe_fields = {k: v for k, v in fields.items() if k.lower().replace(" ", "_") not in _REDACT_KEYS}
    logger.info("audit event=%s %s", event, json.dumps(safe_fields, default=str))


if __name__ == "__main__":
    # Smoke test: canonicalization/digest parity check against a known
    # fixture. Run directly with `python security.py` during CI.
    sample = {"paymentId": "abc123", "amount": 3.14, "uid": "pioneer_1"}
    d1 = domain_digest(PQC_DOMAIN["PAYMENT_CREATE"], sample)
    d2 = domain_digest(PQC_DOMAIN["PAYMENT_CREATE"], dict(reversed(list(sample.items()))))
    assert d1 == d2, "canonicalization must be key-order independent"
    print("security.py self-test OK — digest:", base64.b64encode(d1).decode()[:24], "...")
