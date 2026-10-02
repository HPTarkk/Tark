-- One-time local setup. Run as the postgres superuser:
--   psql -h localhost -U postgres -f backend/scripts/create-local-db.sql
-- Development password only; never reuse it anywhere real.
CREATE ROLE tark LOGIN PASSWORD 'tark';
CREATE DATABASE tark OWNER tark;
CREATE DATABASE tark_test OWNER tark;
