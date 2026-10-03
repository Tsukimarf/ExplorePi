#!/bin/sh
# Menjalankan file db/migrations/*.sql berurutan, sekali saja per file.
set -eu
: "${PGHOST:?}" "${PGUSER:?}" "${PGDATABASE:?}" "${PGPASSWORD:?}" "${APP_DB_PASSWORD:?}"

q() { psql -X -q -v ON_ERROR_STOP=1 -v "app_password=$APP_DB_PASSWORD" "$@"; }

q -c "CREATE TABLE IF NOT EXISTS schema_migrations (
        version    TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now())"

for f in /db/migrations/*.sql; do
  v=$(basename "$f")
  done_flag=$(q -tA -c "SELECT 1 FROM schema_migrations WHERE version = '$v'")
  if [ "$done_flag" = "1" ]; then
    echo "skip   $v"
    continue
  fi
  echo "apply  $v"
  q -1 -f "$f" -c "INSERT INTO schema_migrations (version) VALUES ('$v')"
done
echo "migrasi selesai"
