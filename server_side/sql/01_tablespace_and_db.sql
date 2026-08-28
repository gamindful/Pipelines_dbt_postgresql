-- Run as the postgres superuser, connected to the "postgres" database.
--   psql -h <host> -U postgres -d postgres -f 01_tablespace_and_db.sql
--
-- Neither statement can run inside a transaction block, so this file must
-- not be wrapped in BEGIN/COMMIT.
--
-- PREREQUISITE (Windows): the target folder must exist AND the Postgres
-- service account must be able to write to it. The service runs as
-- NT AUTHORITY\NetworkService, not as the logged-in user:
--   mkdir  "C:\Users\Gamaliel\Documents\G\databases\postgres_local_server\pgdata\analytics_tablespace"
--   icacls "C:\Users\Gamaliel\Documents\G\databases\postgres_local_server\pgdata\analytics_tablespace" /grant "NT AUTHORITY\NetworkService:(OI)(CI)F"
-- The grant is lost if the folder is deleted and recreated.

CREATE TABLESPACE analytics_tablespace
    LOCATION 'C:/Users/Gamaliel/Documents/G/databases/postgres_local_server/pgdata/analytics_tablespace';

CREATE DATABASE analytics_lab
    WITH TABLESPACE = analytics_tablespace
    ENCODING = 'UTF8';

COMMENT ON DATABASE analytics_lab IS
    'Analytics engineering portfolio. ONE database, one schema per domain. PostgreSQL cannot join across databases, so every project lives here.';
