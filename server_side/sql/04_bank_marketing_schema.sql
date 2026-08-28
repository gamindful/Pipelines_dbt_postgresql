-- Project 2 — Campaign Funnel, Incrementally
-- Run as the postgres superuser, connected to analytics_lab.
--   psql -U postgres -d analytics_lab -f 04_bank_marketing_schema.sql
--
-- UCI 222 "Bank Marketing" (Portuguese retail bank). ~45,000 contact attempts.
-- Source file bank-full.csv is SEMICOLON-delimited with a quoted header.
-- Idempotent: safe to re-run.

CREATE SCHEMA IF NOT EXISTS bank_marketing AUTHORIZATION gama;
GRANT USAGE, CREATE ON SCHEMA bank_marketing TO gama;

CREATE TABLE IF NOT EXISTS bank_marketing.campaign_contacts (
    contact_id    BIGSERIAL PRIMARY KEY,
    age           SMALLINT,
    job           TEXT,
    marital       TEXT,
    education     TEXT,
    credit_default TEXT,          -- "default" is reserved; renamed at load time
    balance       NUMERIC(14,2),
    housing       TEXT,
    loan          TEXT,
    contact       TEXT,
    day           SMALLINT,
    month         TEXT,
    duration      INTEGER,        -- seconds; leaks the outcome, exclude from models
    campaign      SMALLINT,
    pdays         INTEGER,        -- -1 means "not previously contacted"
    previous      SMALLINT,
    poutcome      TEXT,
    y             TEXT,           -- 'yes' / 'no' — subscribed a term deposit
    source        TEXT        NOT NULL DEFAULT 'uci-222',
    loaded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bank_marketing_y
    ON bank_marketing.campaign_contacts (y);

COMMENT ON TABLE bank_marketing.campaign_contacts IS
    'UCI 222. Grain: one row per contact attempt. Target: y. NOTE: duration is only known after the call ends, so it must be excluded from any predictive model.';

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA bank_marketing TO gama;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA bank_marketing TO gama;
ALTER DEFAULT PRIVILEGES FOR ROLE gama IN SCHEMA bank_marketing
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO gama;
