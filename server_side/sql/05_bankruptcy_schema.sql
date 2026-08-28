-- Project 3 — Bankruptcy Signals Under Contract
-- Run as the postgres superuser, connected to analytics_lab.
--   psql -U postgres -d analytics_lab -f 05_bankruptcy_schema.sql
--
-- Two sources, ~160 financial ratios between them and no shared naming:
--   UCI 365  Polish companies bankruptcy   ARFF, 5 files (1..5 year horizon), 64 attrs
--   UCI 572  Taiwanese bankruptcy          CSV, ~96 columns
--
-- The wide ratio tables are NOT declared here. Their columns are created by
-- load_uci.py from the actual file headers, because hand-writing 160 column
-- names nobody has read is how silent mismatches happen. This file creates
-- the schema and the privileges the loader needs.
--
-- Idempotent: safe to re-run.

CREATE SCHEMA IF NOT EXISTS bankruptcy AUTHORIZATION gama;
GRANT USAGE, CREATE ON SCHEMA bankruptcy TO gama;

COMMENT ON SCHEMA bankruptcy IS
    'Project 3 sources. Tables polish_bankruptcy and taiwanese_bankruptcy are created by load_uci.py from the source headers; every column lands as text or numeric and is cast in staging.';

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA bankruptcy TO gama;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA bankruptcy TO gama;
ALTER DEFAULT PRIVILEGES FOR ROLE gama IN SCHEMA bankruptcy
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO gama;
