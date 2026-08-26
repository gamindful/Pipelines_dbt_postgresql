-- Run as the postgres superuser, connected to the "postgres" database.
-- Mirrors 01_tablespace_and_db.sql, for the credit-risk domain.
--
-- CREATE TABLESPACE and CREATE DATABASE cannot run inside a transaction
-- block, so this file must not be wrapped in BEGIN/COMMIT.
--
-- PREREQUISITE: the target folder must exist AND the Postgres service
-- account must be able to write to it:
--   mkdir  .\pgdata\credit_tablespace
--   icacls ".\pgdata\credit_tablespace" /grant "NT AUTHORITY\NetworkService:(OI)(CI)F"

CREATE TABLESPACE credit_tablespace
    LOCATION 'C:/Users/Gamaliel/Documents/GitHub/Financial_analytics/pgdata/credit_tablespace';

CREATE DATABASE credit_risk
    WITH TABLESPACE = credit_tablespace
    ENCODING = 'UTF8';

COMMENT ON DATABASE credit_risk IS
    'Credit risk analytics (UCI Taiwan default + Statlog German credit). Separate DB from findata: no cross-database joins are possible.';
