-- Run as the postgres superuser, connected to the findata database.
-- Creates the app role used by the Python loader, the crypto_fx schema,
-- and the core tables. Password is substituted from psql variable
-- :app_password (passed with -v app_password=... on the command line so
-- it never has to be hardcoded in this file).

CREATE ROLE app_findata WITH LOGIN PASSWORD :'app_password';

CREATE SCHEMA IF NOT EXISTS crypto_fx AUTHORIZATION app_findata;

GRANT CONNECT ON DATABASE findata TO app_findata;
GRANT USAGE, CREATE ON SCHEMA crypto_fx TO app_findata;
ALTER ROLE app_findata SET search_path = crypto_fx, public;

SET search_path = crypto_fx;

CREATE TABLE IF NOT EXISTS crypto_fx.assets (
    asset_id        SERIAL PRIMARY KEY,
    symbol          TEXT NOT NULL UNIQUE,
    asset_type      TEXT NOT NULL CHECK (asset_type IN ('crypto', 'fx')),
    base_currency   TEXT NOT NULL,
    quote_currency  TEXT NOT NULL,
    display_name    TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS crypto_fx.price_history (
    price_id     BIGSERIAL PRIMARY KEY,
    asset_id     INTEGER NOT NULL REFERENCES crypto_fx.assets(asset_id) ON DELETE CASCADE,
    trade_date   DATE NOT NULL,
    open         NUMERIC(20,8),
    high         NUMERIC(20,8),
    low          NUMERIC(20,8),
    close        NUMERIC(20,8),
    adj_close    NUMERIC(20,8),
    volume       NUMERIC(24,4),
    source       TEXT NOT NULL DEFAULT 'yfinance',
    loaded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (asset_id, trade_date)
);

CREATE INDEX IF NOT EXISTS idx_price_history_date ON crypto_fx.price_history (trade_date);

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA crypto_fx TO app_findata;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA crypto_fx TO app_findata;
ALTER DEFAULT PRIVILEGES FOR ROLE app_findata IN SCHEMA crypto_fx
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_findata;
