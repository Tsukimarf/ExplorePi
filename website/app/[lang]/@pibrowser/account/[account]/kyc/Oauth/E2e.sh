#!/bin/sh
# Test end-to-end: docker compose up -> migrate -> request nyata ke API.
# Jalankan dari root project: ./test/e2e.sh
#
# Butuh file .env (lihat .env.example). Script ini TIDAK menghapus volume
# di awal, tapi akan docker compose down di akhir kecuali KEEP_UP=1.
set -eu
cd "$(dirname "$0")/.."

API="http://127.0.0.1:3001"
FAIL=0

pass() { echo "OK   $1"; }
fail() { echo "GAGAL $1"; FAIL=1; }

cleanup() {
  if [ "${KEEP_UP:-0}" != "1" ]; then
    echo "--- docker compose down -v ---"
    docker compose down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "--- docker compose up (build + migrate otomatis) ---"
docker compose up -d --build

echo "--- menunggu API siap ---"
i=0
until curl -fs "$API/health" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "API tidak siap setelah 30 detik"
    docker compose logs --tail=50
    exit 1
  fi
  sleep 1
done

# 1. health check
body=$(curl -fs "$API/health")
case "$body" in
  *'"ok":true'*) pass "GET /health" ;;
  *) fail "GET /health -> $body" ;;
esac

# 2. akun yang tidak ada -> 404
code=$(curl -s -o /dev/null -w '%{http_code}' "$API/api/en/account/akun-tidak-ada-xyz")
[ "$code" = "404" ] && pass "GET akun tidak ada -> 404" || fail "GET akun tidak ada -> $code (mau 404)"

# 3. endpoint yang butuh login tanpa token -> 401
code=$(curl -s -o /dev/null -w '%{http_code}' "$API/api/me")
[ "$code" = "401" ] && pass "GET /api/me tanpa token -> 401" || fail "GET /api/me tanpa token -> $code (mau 401)"

# 4. buat akun demo langsung lewat psql (belum ada endpoint signup),
#    lalu pastikan endpoint publik bisa membacanya
docker compose exec -T db psql -U explorepi -d explorepi -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO accounts (username, lang) VALUES ('e2e_test_user', 'en')
ON CONFLICT (username) DO NOTHING;
INSERT INTO account_profiles (account_id, display_name)
SELECT id, 'E2E Test' FROM accounts WHERE username = 'e2e_test_user'
ON CONFLICT (account_id) DO NOTHING;
SQL

body=$(curl -fs "$API/api/en/account/e2e_test_user")
case "$body" in
  *'"username":"e2e_test_user"'*) pass "GET akun yang ada -> data benar" ;;
  *) fail "GET akun yang ada -> $body" ;;
esac

# 5. bersihkan data uji
docker compose exec -T db psql -U explorepi -d explorepi -q \
  -c "DELETE FROM accounts WHERE username = 'e2e_test_user'" >/dev/null

echo "---------------------------------"
if [ "$FAIL" = "0" ]; then
  echo "SEMUA TEST E2E LULUS"
else
  echo "ADA TEST E2E YANG GAGAL"
fi
exit "$FAIL"
