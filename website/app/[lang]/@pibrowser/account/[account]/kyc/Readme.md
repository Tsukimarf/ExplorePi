# crypto-app-backend

Backend ExplorePi: API Node.js, worker Go, service keamanan post-quantum Python, database PostgreSQL.

```
crypto-app-backend/
├── api/                     # Node.js (Express) - API untuk frontend
├── services/
│   ├── go-worker/           # Go - cleanup & rekonsiliasi transaksi
│   └── pq-security/         # Python (FastAPI) - ML-KEM + AES-GCM
├── db/schema.sql            # PostgreSQL
├── docker-compose.yml
└── .env.example
```

## Menjalankan
```bash
cp .env.example .env
# isi POSTGRES_PASSWORD, BLIND_INDEX_KEY, INTERNAL_TOKEN (openssl rand -hex 32)
docker compose up -d --build
curl http://127.0.0.1:3001/health
```

## Catatan
- kms.py hanya untuk development; produksi pakai Vault/KMS.
- Ganti password role `explorepi_app` di db/schema.sql.
- Jangan commit file .env.
