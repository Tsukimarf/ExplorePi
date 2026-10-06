# Unit test & end-to-end

| Lokasi | Alat | Jalankan |
|---|---|---|
| `api/test/` | vitest + supertest | `cd api && npm install && npm test` |
| `services/go-worker/internal/*_test.go` | `go test` | `cd services/go-worker && go test ./...` |
| `services/pq-security/tests/` | pytest | `cd services/pq-security && pip install -r requirements-dev.txt && pytest -q` |
| `test/e2e.sh` | docker compose + curl | `./test/e2e.sh` (dari root project) |

## Catatan
- Test Node.js dan Python me-mock database (`pg`/`asyncpg`), jadi bisa jalan
  tanpa PostgreSQL nyata.
- Test Go di `internal/` hanya menguji logika murni (status, waktu "stale"),
  bukan query database, supaya tidak butuh koneksi nyata.
- 3 test di `tests/test_crypto.py` otomatis dilewati (`skip`) jika liboqs
  belum terpasang di mesin Anda. Di dalam container Docker (lihat
  `services/pq-security/Dockerfile`) liboqs sudah ada, jadi test itu jalan
  penuh di sana / di CI.
- `test/e2e.sh` menjalankan `docker compose up -d --build` (migrasi jalan
  otomatis lewat service `migrate`), lalu mengetes `/health`, akun yang tidak
  ada (404), endpoint butuh login tanpa token (401), dan akun yang memang
  ada. Di akhir, `docker compose down -v` berjalan otomatis kecuali
  `KEEP_UP=1 ./test/e2e.sh`.
