-- 002_roles: user aplikasi dengan hak minimum (password dari :app_password)
SELECT format('CREATE ROLE explorepi_app LOGIN PASSWORD %L', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'explorepi_app')
\gexec

SELECT format('ALTER ROLE explorepi_app PASSWORD %L', :'app_password')
\gexec

ALTER ROLE explorepi_app SET statement_timeout = '30s';
ALTER ROLE explorepi_app SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE explorepi_app SET lock_timeout = '10s';

GRANT USAGE ON SCHEMA public TO explorepi_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO explorepi_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO explorepi_app;
REVOKE UPDATE, DELETE ON audit_logs FROM explorepi_app;

-- tabel/sequence baru otomatis dapat hak yang sama
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO explorepi_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO explorepi_app;

REVOKE ALL ON schema_migrations FROM explorepi_app;
