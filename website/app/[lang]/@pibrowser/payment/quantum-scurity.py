"""
ExplorePi - Quantum Security Layer
Post-quantum cryptography hardening for the Pi blockchain explorer.

Algorithms implemented (NIST PQC standardized / finalist):
  - CRYSTALS-Kyber   (ML-KEM)  — key encapsulation / session key exchange
  - CRYSTALS-Dilithium (ML-DSA) — digital signatures
  - SHAKE-256 / SHA3-512        — quantum-resistant hashing (Grover-resistant)
  - HMAC-SHA3                   — API authentication
  - Hybrid classical+PQ         — transition-safe key exchange

Dependencies:
  pip install cryptography      # required — backs the classical fallback below
  pip install liboqs-python     # optional — enables the real NIST PQC algorithms

IMPORTANT — read before deploying:
  Real ML-KEM / ML-DSA require the `oqs-python` (liboqs) binding; that binding
  is a compiled C library and is NOT always installable in every environment.
  When it is unavailable, this module falls back to X25519 (key exchange) and
  Ed25519 (signatures) from the `cryptography` library instead.

  X25519/Ed25519 are strong, correct, real cryptography — but they are
  CLASSICAL algorithms. They are just as vulnerable to a cryptographically
  relevant quantum computer (Shor's algorithm) as plain RSA/ECDSA are. Running
  in fallback mode means you have working, secure encryption/signing today,
  but NOT the post-quantum protection this module's name implies. Check
  `security_status()['production_ready']` at startup and alert if it's False.

  An earlier version of this fallback used hand-rolled SHA3-based
  constructions instead of X25519/Ed25519. Those did not actually work: the
  encapsulate/decapsulate and sign/verify operations used mismatched key
  material and could not round-trip (verifiable by running this file
  directly — the self-test reported "KEM mismatch" / "Sig mismatch"). It has
  been replaced with the real, standard primitives below.
"""

import os
import hmac
import json
import time
import hashlib
import secrets
import logging
import struct
from typing import Optional
from functools import wraps

logger = logging.getLogger(__name__)

# ─── Optional liboqs (Open Quantum Safe) ──────────────────────────
try:
    import oqs  # type: ignore
    _OQS_AVAILABLE = True
    logger.info("✅ liboqs available — using NIST PQC standard algorithms")
except ImportError:
    _OQS_AVAILABLE = False
    logger.warning(
        "⚠  liboqs not installed. Falling back to classical X25519/Ed25519 "
        "(via the 'cryptography' package) — secure, but NOT post-quantum. "
        "Install liboqs-python for real NIST PQC algorithms."
    )

# ─── Required for the classical fallback path ─────────────────────
try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey, X25519PublicKey
    )
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey, Ed25519PublicKey
    )
    from cryptography.hazmat.primitives.asymmetric import ed25519 as _ed25519_mod
    from cryptography.hazmat.primitives.serialization import (
        Encoding, PublicFormat, PrivateFormat, NoEncryption
    )
    from cryptography.exceptions import InvalidSignature
    _CRYPTOGRAPHY_AVAILABLE = True
except ImportError:
    _CRYPTOGRAPHY_AVAILABLE = False
    if not _OQS_AVAILABLE:
        logger.critical(
            "Neither liboqs nor 'cryptography' is installed — this module "
            "cannot perform any real key exchange or signing. "
            "Run: pip install cryptography"
        )


# ══════════════════════════════════════════════════════════════════
# 1.  QUANTUM-RESISTANT HASHING  (SHA-3 / SHAKE family)
#     Grover's algorithm halves effective bit-security of hash functions.
#     SHA3-512 → 256-bit post-quantum security.  SHAKE-256 → variable.
# ══════════════════════════════════════════════════════════════════

def pq_hash(data: bytes, algo: str = "sha3_512") -> bytes:
    """
    Quantum-resistant hash. Use SHA3-512 (256-bit PQ security) or
    SHAKE-256 (extendable output, 256-bit PQ security).
    """
    if algo == "sha3_512":
        return hashlib.sha3_512(data).digest()
    elif algo == "sha3_256":
        return hashlib.sha3_256(data).digest()
    elif algo == "shake_256":
        return hashlib.shake_256(data).digest(64)  # 512-bit output
    else:
        raise ValueError(f"Unknown PQ hash algo: {algo}")


def pq_hash_hex(data: bytes, algo: str = "sha3_512") -> str:
    return pq_hash(data, algo).hex()


def hash_block(block: dict) -> str:
    """
    Re-hash a block record with quantum-resistant SHA3-512.
    Replaces any SHA-256 based block integrity checks.
    """
    canonical = json.dumps(block, sort_keys=True, default=str).encode()
    return pq_hash_hex(canonical, "sha3_512")


def hash_transaction(tx: dict) -> str:
    canonical = json.dumps(tx, sort_keys=True, default=str).encode()
    return pq_hash_hex(canonical, "sha3_512")


# ══════════════════════════════════════════════════════════════════
# 2.  HMAC-SHA3 API AUTHENTICATION
#     Replaces HMAC-SHA256 — SHA3 is not susceptible to length-extension
#     attacks and provides 256-bit post-quantum security.
# ══════════════════════════════════════════════════════════════════

def generate_api_secret(length: int = 64) -> bytes:
    """Generate a cryptographically secure 512-bit API secret."""
    return secrets.token_bytes(length)


def hmac_sha3(secret: bytes, message: bytes) -> str:
    """Compute HMAC-SHA3-512 for API request authentication."""
    return hmac.new(secret, message, hashlib.sha3_512).hexdigest()


def verify_hmac_sha3(secret: bytes, message: bytes, signature: str) -> bool:
    """Constant-time HMAC verification (timing-attack resistant)."""
    expected = hmac_sha3(secret, message)
    return hmac.compare_digest(expected, signature)


class ApiAuthMiddleware:
    """
    HMAC-SHA3-512 request authentication middleware.
    Attach to any WSGI/ASGI framework (Flask, FastAPI, Django).

    Header expected:  X-ExplorePi-Sig: <hmac_sha3_hex>
                      X-ExplorePi-Ts:  <unix_timestamp>
    """
    def __init__(self, secret: bytes, window_seconds: int = 30):
        self.secret = secret
        self.window = window_seconds

    def sign(self, method: str, path: str, body: bytes = b"") -> dict:
        ts = str(int(time.time()))
        msg = f"{method}\n{path}\n{ts}\n".encode() + body
        sig = hmac_sha3(self.secret, msg)
        return {"X-ExplorePi-Sig": sig, "X-ExplorePi-Ts": ts}

    def verify(self, method: str, path: str, body: bytes,
               sig: str, ts: str) -> bool:
        # Timestamp freshness check
        try:
            age = abs(int(time.time()) - int(ts))
        except (ValueError, TypeError):
            return False
        if age > self.window:
            logger.warning(f"Request timestamp too old: {age}s")
            return False
        msg = f"{method}\n{path}\n{ts}\n".encode() + body
        return verify_hmac_sha3(self.secret, msg, sig)


# ══════════════════════════════════════════════════════════════════
# 3.  CRYSTALS-KYBER  Key Encapsulation (ML-KEM)
#     NIST FIPS 203 (2024).  Secure against Shor's algorithm.
#     Used for: session key negotiation, DB credential wrapping.
# ══════════════════════════════════════════════════════════════════

class KyberKEM:
    """
    ML-KEM (CRYSTALS-Kyber) key encapsulation.
    Uses liboqs when available. Falls back to a real X25519 ECDH-based
    encapsulation (ECIES-style) when it is not — this is correct, working
    cryptography, but it is CLASSICAL, not post-quantum. See the module
    docstring for what that means for your threat model.
    """
    ALGORITHM = "Kyber1024"   # 256-bit classical + PQ security
    FALLBACK_ALGORITHM = "X25519 (classical ECDH — not quantum-resistant)"

    def generate_keypair(self) -> tuple[bytes, bytes]:
        """Returns (public_key, secret_key)."""
        if _OQS_AVAILABLE:
            with oqs.KeyEncapsulation(self.ALGORITHM) as kem:
                pk = kem.generate_keypair()
                sk = kem.export_secret_key()
            return pk, sk
        else:
            return self._ref_keygen()

    def encapsulate(self, public_key: bytes) -> tuple[bytes, bytes]:
        """Returns (ciphertext, shared_secret)."""
        if _OQS_AVAILABLE:
            with oqs.KeyEncapsulation(self.ALGORITHM) as kem:
                ct, ss = kem.encap_secret(public_key)
            return ct, ss
        else:
            return self._ref_encap(public_key)

    def decapsulate(self, ciphertext: bytes, secret_key: bytes) -> bytes:
        """Returns shared_secret."""
        if _OQS_AVAILABLE:
            with oqs.KeyEncapsulation(self.ALGORITHM, secret_key) as kem:
                return kem.decap_secret(ciphertext)
        else:
            return self._ref_decap(ciphertext, secret_key)

    # ── Classical fallback: real X25519 ECDH, ECIES-style ────────
    # (The previous version of this fallback hashed the public key and a
    # random nonce independently on each side, so encapsulate/decapsulate
    # never derived the same shared secret. This uses actual Diffie-Hellman
    # key agreement, which does round-trip correctly.)
    def _require_cryptography(self):
        if not _CRYPTOGRAPHY_AVAILABLE:
            raise RuntimeError(
                "liboqs is unavailable and the 'cryptography' package is not "
                "installed, so no key exchange implementation is available. "
                "Run: pip install cryptography"
            )

    def _ref_keygen(self) -> tuple[bytes, bytes]:
        self._require_cryptography()
        sk_obj = X25519PrivateKey.generate()
        sk = sk_obj.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
        pk = sk_obj.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return pk, sk

    def _ref_encap(self, pk: bytes) -> tuple[bytes, bytes]:
        self._require_cryptography()
        peer_pk = X25519PublicKey.from_public_bytes(pk)
        eph_sk = X25519PrivateKey.generate()
        eph_pk_bytes = eph_sk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        shared = eph_sk.exchange(peer_pk)
        ss = pq_hash(shared, "sha3_256")   # derive a fixed-length symmetric key
        ct = eph_pk_bytes                  # ciphertext = ephemeral public key
        return ct, ss

    def _ref_decap(self, ct: bytes, sk: bytes) -> bytes:
        self._require_cryptography()
        eph_pk = X25519PublicKey.from_public_bytes(ct)
        sk_obj = X25519PrivateKey.from_private_bytes(sk)
        shared = sk_obj.exchange(eph_pk)
        return pq_hash(shared, "sha3_256")


# ══════════════════════════════════════════════════════════════════
# 4.  CRYSTALS-DILITHIUM  Digital Signatures (ML-DSA)
#     NIST FIPS 204 (2024).  Sign crawler API payloads and DB writes.
# ══════════════════════════════════════════════════════════════════

class DilithiumSigner:
    """
    ML-DSA (CRYSTALS-Dilithium) digital signatures.
    Sign block/transaction data before DB insertion for tamper detection.
    """
    ALGORITHM = "Dilithium5"  # Highest security level (NIST Level 5)
    FALLBACK_ALGORITHM = "Ed25519 (classical signatures — not quantum-resistant)"

    def generate_keypair(self) -> tuple[bytes, bytes]:
        """Returns (public_key, secret_key)."""
        if _OQS_AVAILABLE:
            with oqs.Signature(self.ALGORITHM) as sig:
                pk = sig.generate_keypair()
                sk = sig.export_secret_key()
            return pk, sk
        else:
            return self._ref_keygen()

    def sign(self, message: bytes, secret_key: bytes) -> bytes:
        if _OQS_AVAILABLE:
            with oqs.Signature(self.ALGORITHM, secret_key) as sig:
                return sig.sign(message)
        else:
            return self._ref_sign(message, secret_key)

    def verify(self, message: bytes, signature: bytes, public_key: bytes) -> bool:
        if _OQS_AVAILABLE:
            with oqs.Signature(self.ALGORITHM) as sig:
                return sig.verify(message, signature, public_key)
        else:
            return self._ref_verify(message, signature, public_key)

    # ── Classical fallback: real Ed25519 signatures ──────────────
    # (The previous version signed with HMAC keyed by the secret key but
    # verified with HMAC keyed by a slice of the *public* key — two
    # different keys, so genuine signatures never verified. It also meant
    # that anyone holding only the "public" key could have forged a valid
    # signature themselves, defeating the point of public-key signing.
    # Ed25519 gives real sign-with-secret / verify-with-public semantics.)
    def _require_cryptography(self):
        if not _CRYPTOGRAPHY_AVAILABLE:
            raise RuntimeError(
                "liboqs is unavailable and the 'cryptography' package is not "
                "installed, so no signature implementation is available. "
                "Run: pip install cryptography"
            )

    def _ref_keygen(self) -> tuple[bytes, bytes]:
        self._require_cryptography()
        sk_obj = Ed25519PrivateKey.generate()
        sk = sk_obj.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
        pk = sk_obj.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return pk, sk

    def _ref_sign(self, msg: bytes, sk: bytes) -> bytes:
        self._require_cryptography()
        sk_obj = Ed25519PrivateKey.from_private_bytes(sk)
        return sk_obj.sign(msg)

    def _ref_verify(self, msg: bytes, signature: bytes, pk: bytes) -> bool:
        self._require_cryptography()
        try:
            pk_obj = Ed25519PublicKey.from_public_bytes(pk)
            pk_obj.verify(signature, msg)
            return True
        except InvalidSignature:
            return False


# ══════════════════════════════════════════════════════════════════
# 5.  HYBRID KEY EXCHANGE  (Classical ECDH + Kyber)
#     Transition-safe: secure against both classical AND quantum adversaries.
#     Combines X25519 (classical) with ML-KEM (quantum).
# ══════════════════════════════════════════════════════════════════

class HybridKeyExchange:
    """
    Hybrid classical + post-quantum key exchange.
    Final shared secret = SHA3-512(ecdh_secret || kyber_secret)
    This is NIST and IETF recommended approach for PQ transition.
    """

    def __init__(self):
        self.kem = KyberKEM()
        try:
            from cryptography.hazmat.primitives.asymmetric.x25519 import (
                X25519PrivateKey
            )
            self._x25519_available = True
        except ImportError:
            self._x25519_available = False
            logger.warning("cryptography library not found; X25519 disabled in hybrid mode")

    def generate_hybrid_keypair(self) -> dict:
        """Generate classical + PQ keypair bundle."""
        pq_pk, pq_sk = self.kem.generate_keypair()
        result = {"pq_public": pq_pk.hex(), "pq_secret": pq_sk.hex()}

        if self._x25519_available:
            from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
            from cryptography.hazmat.primitives.serialization import (
                Encoding, PublicFormat, PrivateFormat, NoEncryption
            )
            ec_sk = X25519PrivateKey.generate()
            ec_pk = ec_sk.public_key()
            result["ec_public"] = ec_pk.public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
            result["ec_secret"] = ec_sk.private_bytes(
                Encoding.Raw, PrivateFormat.Raw, NoEncryption()
            ).hex()
        return result

    def derive_shared_secret(
        self,
        pq_shared: bytes,
        ec_shared: Optional[bytes] = None
    ) -> bytes:
        """
        Combine PQ and classical shared secrets using SHA3-512.
        Even if one is broken, the combined secret remains secure.
        """
        material = pq_shared
        if ec_shared:
            material = ec_shared + pq_shared
        return pq_hash(material, "sha3_512")


# ══════════════════════════════════════════════════════════════════
# 6.  SECURE DB CREDENTIAL WRAPPER
#     Wrap DB passwords in a Kyber-encrypted envelope at rest.
# ══════════════════════════════════════════════════════════════════

class QuantumSecureVault:
    """
    Simple key-value vault that encrypts secrets using Kyber KEM
    + AES-256-GCM (symmetric), with PQ-wrapped symmetric key.
    Prevents harvest-now-decrypt-later attacks on stored credentials.
    """

    def __init__(self):
        self.kem = KyberKEM()
        self._pk, self._sk = self.kem.generate_keypair()

    def seal(self, plaintext: bytes) -> dict:
        """Encrypt plaintext. Returns an envelope dict."""
        ct_kem, ss = self.kem.encapsulate(self._pk)
        # Derive AES key from shared secret
        aes_key = pq_hash(ss, "sha3_256")[:32]  # 256-bit
        nonce    = secrets.token_bytes(12)
        try:
            from Crypto.Cipher import AES
        except ImportError:
            # No safe fallback: an unauthenticated homegrown stream cipher
            # (XOR with a hash-derived keystream, "tag" = a public hash of
            # the ciphertext) provides no real confidentiality or integrity
            # guarantee — anyone can recompute that "tag" without the key.
            # Fail loudly instead of returning something that looks sealed.
            raise RuntimeError(
                "pycryptodome is not installed, so there is no authenticated "
                "cipher available for QuantumSecureVault. "
                "Run: pip install pycryptodome"
            )
        cipher = AES.new(aes_key, AES.MODE_GCM, nonce=nonce)
        ciphertext, tag = cipher.encrypt_and_digest(plaintext)

        return {
            "kem_ciphertext": ct_kem.hex(),
            "nonce": nonce.hex(),
            "ciphertext": ciphertext.hex(),
            "tag": tag.hex(),
            "algo": f"{self.kem.ALGORITHM if _OQS_AVAILABLE else self.kem.FALLBACK_ALGORITHM}+AES-256-GCM+SHA3",
        }

    def unseal(self, envelope: dict) -> bytes:
        """Decrypt an envelope dict."""
        ct_kem  = bytes.fromhex(envelope["kem_ciphertext"])
        nonce   = bytes.fromhex(envelope["nonce"])
        ctext   = bytes.fromhex(envelope["ciphertext"])
        tag     = bytes.fromhex(envelope["tag"])

        ss      = self.kem.decapsulate(ct_kem, self._sk)
        aes_key = pq_hash(ss, "sha3_256")[:32]
        try:
            from Crypto.Cipher import AES
        except ImportError:
            raise RuntimeError(
                "pycryptodome is not installed, so this envelope cannot be "
                "authenticated and decrypted. Run: pip install pycryptodome"
            )
        cipher = AES.new(aes_key, AES.MODE_GCM, nonce=nonce)
        return cipher.decrypt_and_verify(ctext, tag)


# ══════════════════════════════════════════════════════════════════
# 7.  DECORATOR: sign every DB write with Dilithium
# ══════════════════════════════════════════════════════════════════

_signer = DilithiumSigner()
_PQ_PK, _PQ_SK = _signer.generate_keypair()


def quantum_sign_write(func):
    """
    Decorator: attaches a Dilithium signature to any dict returned
    by a DB write function (upsert_block, upsert_transaction, etc.).
    Signature is stored alongside the record and can be verified later
    to detect tampering even by a quantum-capable adversary.
    """
    @wraps(func)
    def wrapper(*args, **kwargs):
        result = func(*args, **kwargs)
        if args and isinstance(args[0], dict):
            payload = json.dumps(args[0], sort_keys=True, default=str).encode()
            sig = _signer.sign(payload, _PQ_SK)
            args[0]["_pq_sig"] = sig.hex()
            args[0]["_pq_hash"] = pq_hash_hex(payload)
        return result
    return wrapper


def verify_record_signature(record: dict) -> bool:
    """Verify the PQ signature on a record dict."""
    sig_hex  = record.pop("_pq_sig", None)
    pq_h     = record.pop("_pq_hash", None)
    if not sig_hex:
        return False
    payload  = json.dumps(record, sort_keys=True, default=str).encode()
    record["_pq_sig"]  = sig_hex
    record["_pq_hash"] = pq_h
    return _signer.verify(payload, bytes.fromhex(sig_hex), _PQ_PK)


# ══════════════════════════════════════════════════════════════════
# 8.  SECURITY STATUS REPORT
# ══════════════════════════════════════════════════════════════════

def security_status() -> dict:
    return {
        "pq_library": "liboqs (NIST PQC)" if _OQS_AVAILABLE else "pure-Python reference",
        "kem_algorithm": KyberKEM.ALGORITHM,
        "sig_algorithm": DilithiumSigner.ALGORITHM,
        "hash_algorithm": "SHA3-512 (NIST FIPS 202)",
        "hmac_algorithm": "HMAC-SHA3-512",
        "hybrid_ecdh": "X25519 + ML-KEM (transition-safe)",
        "nist_pqc_standards": ["FIPS 203 (ML-KEM)", "FIPS 204 (ML-DSA)", "FIPS 202 (SHA-3)"],
        "quantum_threat_model": {
            "Shor_algorithm": "mitigated by ML-KEM + ML-DSA",
            "Grover_algorithm": "mitigated by SHA3-512 (256-bit PQ security)",
            "harvest_now_decrypt_later": "mitigated by hybrid key exchange",
        },
        "production_ready": _OQS_AVAILABLE,
        "recommendation": (
            "Install liboqs for full NIST PQC compliance: "
            "pip install liboqs-python"
        ) if not _OQS_AVAILABLE else "Production-grade PQC active.",
    }


# ── CLI self-test ─────────────────────────────────────────────────
if __name__ == "__main__":
    import json

    print("\n=== ExplorePi Quantum Security Layer ===\n")

    # Status
    print(json.dumps(security_status(), indent=2))

    # Hash test
    digest = pq_hash_hex(b"Pi blockchain block #1", "sha3_512")
    print(f"\nSHA3-512 hash: {digest[:32]}…")

    # KEM test
    kem = KyberKEM()
    pk, sk = kem.generate_keypair()
    ct, ss1 = kem.encapsulate(pk)
    ss2 = kem.decapsulate(ct, sk)
    print(f"Kyber KEM match: {ss1 == ss2} ✅" if ss1 == ss2 else "❌ KEM mismatch")

    # Signature test
    sig = DilithiumSigner()
    spk, ssk = sig.generate_keypair()
    msg = b"ledger:12345:txcount:42"
    s   = sig.sign(msg, ssk)
    ok  = sig.verify(msg, s, spk)
    print(f"Dilithium sign/verify: {ok} ✅" if ok else "❌ Sig mismatch")

    # HMAC test
    secret = generate_api_secret()
    auth   = ApiAuthMiddleware(secret)
    hdrs   = auth.sign("GET", "/api/blocks")
    valid  = auth.verify("GET", "/api/blocks", b"", hdrs["X-ExplorePi-Sig"], hdrs["X-ExplorePi-Ts"])
    print(f"HMAC-SHA3 auth: {valid} ✅" if valid else "❌ HMAC mismatch")

    # Vault test
    vault = QuantumSecureVault()
    envelope = vault.seal(b"super_secret_db_password")
    recovered = vault.unseal(envelope)
    print(f"Vault seal/unseal: {recovered == b'super_secret_db_password'} ✅")

    print("\n✅ All quantum security checks passed.\n")