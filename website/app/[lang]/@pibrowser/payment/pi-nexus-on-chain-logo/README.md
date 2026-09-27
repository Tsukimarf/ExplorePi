# pqc_body — Post-Quantum Cryptography module

Update for `pi-nexus-on-chain-Logo`, extending the multi-language
`quantum_body` suite (SQL/JS/Python/C++/JSON) with real NIST-standardized
post-quantum cryptography — not the "quantum" branding theme, the actual
FIPS 203/204/205 algorithms — so on-chain signing has a defined migration
path off Ed25519-only security.

## Why

Stellar/Soroban (and Pi Network by extension) sign transactions with
Ed25519, which is not quantum-resistant. A cryptographically relevant
quantum computer would break Ed25519 but not ML-KEM/ML-DSA. This module
adds those algorithms alongside the existing classical signer, in
**hybrid mode**: every transaction gets both a classical and a PQ
signature, and verifiers can require both until the fleet is fully
migrated.

## Algorithms (NIST FIPS 203/204/205)

| Purpose | Algorithm | Level | Notes |
|---|---|---|---|
| Key encapsulation | ML-KEM-768 (Kyber) | L3 | default |
| Signatures | ML-DSA-65 (Dilithium) | L3 | default |
| Signatures (fallback) | SLH-DSA / SPHINCS+-128s | L1 | hash-based, larger sigs, conservative |

512/1024-bit KEM and 44/87 signature variants are also implemented for
lower/higher security tiers — see `pqc/config/pqc_body.json`.

## Folder structure

```
pi-nexus-pqc/
└── pqc/
    ├── cpp/
    │   ├── pqc_body.hpp      # C++17 interface (KEM + SIG + hybrid signing)
    │   └── pqc_body.cpp      # liboqs-backed implementation
    ├── python/
    │   └── pqc_body.py       # liboqs-python bindings, mirrors the C++ API
    ├── js/
    │   └── pqc_body.js       # @noble/post-quantum (pure JS, no native deps)
    ├── sql/
    │   └── pqc_body.sql      # pqc_keys, pqc_hybrid_signatures, migration status
    └── config/
        └── pqc_body.json     # algorithm manifest + rollout config
```

## Install

- **C++**: build/install [liboqs](https://github.com/open-quantum-safe/liboqs)
  first, then `g++ -std=c++17 -O2 pqc_body.cpp -loqs -o pqc_body`.
- **Python**: `pip install liboqs-python` (wraps the same liboqs C library).
- **JS/Node**: `npm install @noble/post-quantum` — pure JavaScript, audited,
  no native compilation required, so it also runs in browser/Pi Browser
  contexts for client-side keygen.
- **SQL**: `psql $DATABASE_URL -f pqc/sql/pqc_body.sql` (Postgres 14+;
  requires `pgcrypto` for `digest()` — `CREATE EXTENSION IF NOT EXISTS pgcrypto;`
  if not already enabled).

## Hybrid transaction flow

1. Account enrolls: generate an ML-DSA-65 keypair, store the **public**
   half in `pqc_keys`, keep the secret key client-side/HSM.
   `pqc_migration_status.stage` moves to `hybrid_enrolled`.
2. On transaction submission, the existing Stellar/Soroban signer
   produces the classical Ed25519 signature as before; `hybrid_sign_transaction()`
   adds an ML-DSA-65 signature over the same serialized tx bytes.
3. Both signatures are stored via `pqc_hybrid_signatures`, keyed by `tx_hash`.
4. Verifiers call `hybrid_verify_transaction(..., require_both=true)`
   and record the outcome with `fn_pqc_record_verification()`.
5. Once enough of the fleet is enrolled and verification is clean,
   flip enforcement fleet-wide (`hybrid_enforced`), and eventually retire
   classical-only acceptance (`pq_only`).

## Note

Built as a fresh module rather than a diff against the live repo — the
existing `quantum_body.*` files describe "quantum transaction processing"
as a branding/theme rather than a specific crypto library, so this adds
the actual PQC primitives (ML-KEM/ML-DSA via liboqs and @noble/post-quantum)
alongside them under `pqc/` rather than overwriting `quantum_body.*`.
Worth confirming against the current `quantum_body.hpp`/`.py` interfaces
before wiring the hybrid signer into the existing transaction pipeline.
