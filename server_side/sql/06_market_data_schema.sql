-- Project 4 — Market Data & External Dependencies
-- Run as the postgres superuser, connected to analytics_lab.
--   psql -U postgres -d analytics_lab -f 06_market_data_schema.sql
--
-- Daily OHLCV for crypto and FX pairs, downloaded with utils/download_dataset.py
-- (yfinance). This is the only source in the portfolio that actually changes,
-- which is what makes source freshness and microbatch incrementals meaningful.
--
-- Idempotent: safe to re-run.

CREATE SCHEMA IF NOT EXISTS market_data AUTHORIZATION gama;
GRANT USAGE, CREATE ON SCHEMA market_data TO gama;

CREATE TABLE IF NOT EXISTS market_data.assets (
    asset_id        SERIAL PRIMARY KEY,
    symbol          TEXT NOT NULL UNIQUE,
    asset_type      TEXT NOT NULL CHECK (asset_type IN ('crypto', 'fx')),
    base_currency   TEXT NOT NULL,
    quote_currency  TEXT NOT NULL,
    display_name    TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS market_data.price_history (
    price_id     BIGSERIAL PRIMARY KEY,
    asset_id     INTEGER NOT NULL REFERENCES market_data.assets(asset_id) ON DELETE CASCADE,
    trade_date   DATE NOT NULL,
    open         NUMERIC(20,8),
    high         NUMERIC(20,8),
    low          NUMERIC(20,8),
    close        NUMERIC(20,8),
    adj_close    NUMERIC(20,8),
    volume       NUMERIC(24,4),
    source       TEXT        NOT NULL DEFAULT 'yfinance',
    loaded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (asset_id, trade_date)          -- lets the loader upsert safely
);

CREATE INDEX IF NOT EXISTS idx_price_history_date
    ON market_data.price_history (trade_date);

COMMENT ON TABLE market_data.price_history IS
    'Grain: one row per asset per trade_date. loaded_at is what dbt source freshness measures -- without it freshness cannot be configured at all.';

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA market_data TO gama;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA market_data TO gama;
ALTER DEFAULT PRIVILEGES FOR ROLE gama IN SCHEMA market_data
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO gama;
