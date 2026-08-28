-- Run as the postgres superuser, connected to "postgres".
-- Roles are CLUSTER-level, so this is not run inside analytics_lab.
--
--   psql -h <host> -U postgres -d postgres -v app_password=... -f 02_role.sql
--
-- MUST be run with -f, not -c. On Windows/psql 18, :'var' interpolation
-- silently fails when the SQL arrives as a -c argument: the colon reaches
-- the parser unsubstituted and you get "syntax error at or near \":\"".
-- The identical text read from a file works correctly.
--
-- Idempotent: safe to re-run.

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gama') THEN
        EXECUTE format('CREATE ROLE gama WITH LOGIN PASSWORD %L', :'app_password');
    ELSE
        EXECUTE format('ALTER ROLE gama WITH PASSWORD %L', :'app_password');
    END IF;
END $$;

GRANT CONNECT ON DATABASE analytics_lab TO gama;
GRANT CREATE  ON DATABASE analytics_lab TO gama;   -- lets dbt create its own schemas

ALTER ROLE gama SET search_path = credit_risk, staging, marts, public;
