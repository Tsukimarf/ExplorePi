# Roadmap — crypto-app-backend (ExplorePi)

Status saat ini: fondasi backend sudah ada (schema, migrasi, API Node.js, worker Go,
service keamanan Python) tapi belum siap produksi. Belum ada autentikasi nyata,
test otomatis, CI/CD, maupun monitoring.

## Fase 0 — Fondasi (selesai)
- [x] Schema database + migrasi bertahap (`db/migrations`)
- [x] API Node.js: route akun, profil, bookmark, secrets
- [x] Service Python: enkripsi ML-KEM-768 + AES-256-GCM
- [x] Worker Go: cleanup sesi/riwayat, rekonsiliasi transaksi
- [x] docker-compose untuk development

## Fase 1 — Autentikasi (belum ada, prioritas tertinggi)
Tanpa ini, tabel `sessions` tidak terisi dan semua endpoint `requireAuth` tidak
bisa dipakai sungguhan.
- [ ] Tentukan metode login: Pi Network OAuth, email+password, atau keduanya
- [ ] Endpoint login/logout yang mengisi tabel `sessions`
- [ ] Hash password dengan argon2id jika pakai password
- [ ] Refresh token / rotasi sesi
- [ ] Rate limit khusus endpoint login (brute-force)

## Fase 2 — Pengujian & kualitas kode
- [ ] Unit test Node.js (vitest/jest) untuk routes dan middleware auth
- [ ] Unit test Go (`go test`) untuk cleanup & reconcile
- [ ] Unit test Python (pytest) untuk crypto.py dan db.py
- [ ] Integration test: docker-compose + request end-to-end
- [ ] Linter: eslint (Node), golangci-lint (Go), ruff (Python)

## Fase 3 — Keamanan lanjutan
- [ ] Ganti `kms.py` file-based dengan Vault/AWS KMS/GCP KMS
- [ ] Rotasi kunci PQ terjadwal (worker Go bisa menangani ini)
- [ ] Tanda tangan ML-DSA pada audit_logs (kolom `signature` sudah ada)
- [ ] TLS antar service jika database diakses lintas jaringan
- [ ] Secrets scanning di CI (mis. gitleaks)
- [ ] Audit dependency (npm audit, pip-audit, govulncheck)

## Fase 4 — Integrasi frontend
- [ ] Hubungkan halaman `[lang]/@pibrowser/account/[account]` ke
      `GET /api/:lang/account/:account`
- [ ] Hubungkan form profil ke `PUT /api/me/profile`
- [ ] UI untuk field sensitif (email/phone) lewat `/api/me/secrets/:field`
- [ ] Tangani error 401/404/409 secara konsisten di UI

## Fase 5 — Observability
- [ ] Structured logging (JSON) di ketiga service
- [ ] Health/readiness check terpisah (`/health` sudah ada, tambah `/ready`)
- [ ] Metrics (Prometheus) + dashboard dasar
- [ ] Alert untuk worker reconcile yang gagal terus-menerus

## Fase 6 — Produksi
- [ ] CI/CD: build & push image Docker, jalankan migrate otomatis
- [ ] Staging environment terpisah dari production
- [ ] Backup terjadwal (pakai `db/scripts/backup.sh`) + backup volume `kms`
- [ ] Restore test berkala (bukan cuma backup, tapi dicoba dipulihkan)
- [ ] Load test API sebelum rilis publik
- [ ] Dokumentasi runbook insiden (DB down, worker macet, dsb.)

## Backlog / belum diprioritaskan
- Notifikasi (push/email)
- Multi-wallet per akun (skema sudah mendukung banyak wallet)
- Dukungan multi-bahasa penuh untuk konten, bukan hanya kolom `lang`
- Rate limit per-akun (bukan hanya per-IP)

---
Perbarui file ini setiap fase selesai atau prioritas berubah. Tandai item dengan `[x]`
saat sudah selesai dan tambahkan tanggal singkat jika perlu riwayat.
