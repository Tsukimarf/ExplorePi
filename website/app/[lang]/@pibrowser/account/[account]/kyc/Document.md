# Roadmap — crypto-app-backend (ExplorePi)

Terakhir diperbarui: 7 Okt 2026

**Legenda:** `[x]` selesai dan teruji · `[~]` sudah ditulis tapi BELUM dijalankan/diverifikasi
di lingkungan nyata · `[ ]` belum dikerjakan

## Ringkasan status

| Area | Status |
|---|---|
| Database (PostgreSQL, 5 migrasi) | Sintaks valid (diparse dengan parser PostgreSQL); belum dijalankan ke Postgres sungguhan |
| API Node.js | 34 unit test lulus (database & pq-security di-mock) |
| Service Python (PQ) | 40 test lulus, 2 file dilewati karena liboqs tidak ada di mesin uji |
| Worker Go | Test ditulis, belum pernah dikompilasi/dijalankan |
| Docker compose + e2e + CI | Ditulis, belum pernah dijalankan |
| Produksi | **Belum siap** (lihat Fase 3 dan 6) |

---

## Fase 0 — Fondasi (selesai)
- [x] Schema database + migrasi bertahap (`db/migrations/001–005`) + script migrate/backup/restore
- [x] Config PostgreSQL (`postgresql.conf`, `pg_hba.conf`) dan user aplikasi hak-minimum
- [x] API Node.js: akun, profil, bookmark, secrets, OAuth, KYC, lisensi
- [x] Service Python: enkripsi post-quantum + lisensi bertanda tangan
- [x] Worker Go: cleanup sesi/riwayat, rekonsiliasi transaksi
- [x] docker-compose (db, migrate, pq-security, api, worker)

## Fase 1 — Autentikasi & akses
- [x] OAuth2 generik + PKCE: `GET /api/auth/:provider/start` dan `/callback`
- [x] Akun otomatis dibuat saat login OAuth pertama; sesi tersimpan (`login_method='oauth'`)
- [x] Token OAuth disimpan terenkripsi PQ (bukan plaintext)
- [ ] Uji OAuth terhadap provider sungguhan (Pi Network: butuh dokumentasi & kredensial; saat ini hanya diuji dengan mock)
- [ ] Endpoint logout / cabut sesi
- [ ] Refresh token & rotasi sesi
- [ ] Rate limit khusus `/api/auth/*` (anti brute-force)
- [ ] Role admin + proteksi endpoint admin (prasyarat Fase 7)
- [ ] Login password (argon2id) — hanya jika dibutuhkan selain OAuth

## Fase 2 — Pengujian & kualitas kode
- [x] Unit test Node.js (vitest + supertest): 34 test
- [x] Unit test Python (pytest): 40 test lulus
- [~] Unit test Go: ditulis (`internal/status_test.go`), belum dijalankan — jalankan `go test ./...`
- [~] End-to-end `test/e2e.sh` (docker compose + curl) — belum dijalankan
- [~] CI GitHub Actions (`.github/workflows/ci.yml`) — belum pernah berjalan
- [~] Test kripto sungguhan (`test_crypto.py`, `test_signing.py`) — otomatis jalan hanya jika liboqs terpasang (ada di image Docker)
- [ ] Integration test dengan PostgreSQL sungguhan untuk `db.py` dan query di route Node.js (saat ini semua query hanya di-mock)
- [ ] Linter: eslint, golangci-lint, ruff
- [ ] Target coverage + laporan di CI

## Fase 3 — Keamanan & lisensi
Model keamanan (tipe enkripsi, `security_profiles`):
- [x] `standard` = ML-KEM-768 + AES-256-GCM, `high` = ML-KEM-1024 + AES-256-GCM
- [x] Pilihan model dibatasi oleh paket (`allowed_security_models`), dicek di pq-security
- [x] Berganti model membuat kunci baru; data lama tetap terbaca dengan kunci lamanya

Model lisensi (`license_plans`, `licenses`):
- [x] Paket `free` / `pro` / `enterprise` (angka batas masih placeholder)
- [x] Lisensi diterbitkan dengan payload kanonik yang ditandatangani **ML-DSA-65**, kunci sistem di `pq_keys` (account_id NULL)
- [x] Verifikasi tanda tangan, deteksi kedaluwarsa (fail-closed), revoke, supersede otomatis saat terbit ulang
- [x] Batas bookmark per paket benar-benar ditegakkan di API (403 `plan_limit_reached`)
- [x] Migrasi 005 dengan hak akses minimum (`license_plans` read-only untuk aplikasi)

Yang masih harus dikerjakan:
- [ ] **Ganti `kms.py` (file-based, dev only) dengan Vault / AWS KMS / GCP KMS — wajib sebelum produksi**
- [ ] Re-enkripsi data lama setelah ganti model/rotasi (saat ini data lama tetap di algoritma lama)
- [ ] Rotasi kunci terjadwal (worker Go)
- [ ] Tanda tangan ML-DSA pada `audit_logs` (kolom `signature` sudah ada, belum diisi)
- [ ] Tegakkan `max_wallets` (belum ada endpoint wallet)
- [ ] Worker Go: tandai lisensi kedaluwarsa jadi `expired` dan panggil `purge_expired_oauth_states()` (fungsi SQL ada, belum dipanggil). Catatan: akses sudah benar karena query selalu mengecek `expires_at`; ini hanya soal kerapian data
- [ ] KYC: review/approve oleh admin dan webhook provider KYC
- [ ] TLS antar service jika database/service dipisah jaringan
- [ ] Audit dependency (npm audit, pip-audit, govulncheck) + secrets scanning (gitleaks) di CI

## Fase 4 — Integrasi frontend (Next.js)
- [ ] Halaman `[lang]/@pibrowser/account/[account]` → `GET /api/:lang/account/:account`
- [ ] Alur login: `GET /api/auth/:provider/start` → redirect → `/callback` → simpan token
- [ ] Halaman `kyc` → `GET/POST /api/me/kyc` (dokumen lewat hosted flow provider, bukan lewat API ini)
- [ ] Halaman pengaturan: profil, model keamanan, paket/lisensi
- [ ] Penanganan error konsisten (401, 403 `plan_limit_reached`/`plan_not_allowed`, 404, 409)

## Fase 5 — Observability
- [ ] Structured logging (JSON) di ketiga service
- [ ] `/ready` terpisah dari `/health` (cek koneksi database)
- [ ] Metrics Prometheus + dashboard dasar
- [ ] Alert: worker reconcile gagal terus, lonjakan 401/403, error pq-security

## Fase 6 — Produksi & operasi
- [ ] Jalankan dan perbaiki hasil nyata dari: `docker compose up`, `test/e2e.sh`, `go test`, CI
- [ ] CI/CD: build & push image, migrate otomatis saat deploy
- [ ] Staging terpisah dari production
- [ ] Backup terjadwal database **dan volume `kms`** (tanpa `kms`, data terenkripsi tidak bisa dipulihkan)
- [ ] Uji restore berkala
- [ ] Load test API
- [ ] Runbook insiden (DB down, worker macet, kunci hilang/bocor)

## Fase 7 — Monetisasi & administrasi lisensi
- [ ] Alur pembayaran → penerbitan lisensi (`POST /accounts/:id/license` di pq-security sudah siap; belum ada pemicunya)
- [ ] Panel/endpoint admin: terbitkan, cabut, lihat lisensi
- [ ] Notifikasi lisensi akan habis
- [ ] Tentukan angka batas paket final (bookmark, wallet, fitur)

## Backlog
- Notifikasi (push/email)
- Multi-wallet per akun (skema sudah mendukung)
- Konten multi-bahasa penuh (bukan hanya kolom `lang`)
- Rate limit per akun (bukan hanya per IP)
- Multi-provider OAuth sekaligus (saat ini satu provider lewat env)

## Keputusan yang masih dibutuhkan dari pemilik proyek
1. Provider OAuth yang dipakai (Pi Network atau lain) dan dokumentasinya
2. Angka batas final tiap paket
3. Siapa yang menerbitkan lisensi (admin manual atau otomatis dari pembayaran)
4. Lisensi perangkat lunak repo (file `LICENSE`: MIT, Apache-2.0, proprietary, dll.) — belum dipilih, sengaja tidak diasumsikan
5. Field sebenarnya di halaman `kyc` frontend (tabel `kyc_verifications` masih kerangka umum)