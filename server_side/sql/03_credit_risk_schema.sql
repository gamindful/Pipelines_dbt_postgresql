-- Run as the postgres superuser, connected to analytics_lab.
--   psql -h <host> -U postgres -d analytics_lab -f 03_credit_risk_schema.sql
--
-- Creates the credit_risk source schema and its two tables. This schema is
-- written ONLY by server_side/utils/load_credit_data.py -- dbt reads it and
-- never writes here, so a bad `dbt run` cannot destroy ingested data.
--
-- Idempotent: safe to re-run.

CREATE SCHEMA IF NOT EXISTS credit_risk AUTHORIZATION gama;
GRANT USAGE, CREATE ON SCHEMA credit_risk TO gama;

SET search_path = credit_risk;

-- ---------------------------------------------------------------------------
-- UCI "Default of Credit Card Clients" (Taiwan, 2005). 30,000 rows. CC BY 4.0.
-- Distributed as .xls with TWO header rows -- the real column names are on the
-- second row; the first is a merged title band.
--
-- Known data-quality issues, to be resolved in the staging model rather than
-- here (raw stays faithful to the source):
--   education  documented as 1-4, but the data also contains 0, 5 and 6
--   marriage   documented as 1-3, but the data also contains 0
-- Those undocumented codes are ~345 rows with wildly inconsistent default
-- rates; collapse them to "other" downstream.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS credit_risk.credit_default (
    client_id           INTEGER PRIMARY KEY,
    limit_bal           NUMERIC(14,2) NOT NULL,
    sex                 SMALLINT      NOT NULL,   -- 1 male, 2 female
    education           SMALLINT      NOT NULL,   -- 1 grad .. 4 other (+ 0,5,6 undocumented)
    marriage            SMALLINT      NOT NULL,   -- 1 married, 2 single, 3 other (+ 0)
    age                 SMALLINT      NOT NULL CHECK (age BETWEEN 0 AND 130),
    pay_0               SMALLINT,                 -- repayment status, most recent month
    pay_2               SMALLINT,
    pay_3               SMALLINT,
    pay_4               SMALLINT,
    pay_5               SMALLINT,
    pay_6               SMALLINT,
    bill_amt1           NUMERIC(14,2),            -- bill statement amounts; negatives are
    bill_amt2           NUMERIC(14,2),            -- legitimate (overpaid balances)
    bill_amt3           NUMERIC(14,2),
    bill_amt4           NUMERIC(14,2),
    bill_amt5           NUMERIC(14,2),
    bill_amt6           NUMERIC(14,2),
    pay_amt1            NUMERIC(14,2),            -- previous payment amounts
    pay_amt2            NUMERIC(14,2),
    pay_amt3            NUMERIC(14,2),
    pay_amt4            NUMERIC(14,2),
    pay_amt5            NUMERIC(14,2),
    pay_amt6            NUMERIC(14,2),
    default_next_month  SMALLINT      NOT NULL CHECK (default_next_month IN (0,1)),
    source              TEXT          NOT NULL DEFAULT 'uci-350',
    loaded_at           TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_credit_default_target
    ON credit_risk.credit_default (default_next_month);

COMMENT ON TABLE credit_risk.credit_default IS
    'UCI 350. Grain: one row per credit card client. Target: default_next_month (22.1% positive).';

-- ---------------------------------------------------------------------------
-- UCI "Statlog German Credit". 1,000 rows. CC BY 4.0.
-- Source file has NO header and is space-delimited. Categorical values are
-- coded (A11, A34, ...); the codebook ships as german.doc inside the zip.
-- Column names below follow that documentation -- verify against german.doc
-- before relying on the semantics. Decoding to readable labels belongs in
-- the staging model, not here.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS credit_risk.german_credit (
    applicant_id             SERIAL PRIMARY KEY,
    checking_status          TEXT,          -- A11..A14
    duration_months          SMALLINT,
    credit_history           TEXT,          -- A30..A34
    purpose                  TEXT,          -- A40..A410
    credit_amount            NUMERIC(12,2),
    savings_status           TEXT,          -- A61..A65
    employment_since         TEXT,          -- A71..A75
    installment_rate         SMALLINT,
    personal_status_sex      TEXT,          -- A91..A95
    other_debtors            TEXT,          -- A101..A103
    residence_since          SMALLINT,
    property_type            TEXT,          -- A121..A124
    age_years                SMALLINT,
    other_installment_plans  TEXT,          -- A141..A143
    housing                  TEXT,          -- A151..A153
    existing_credits         SMALLINT,
    job                      TEXT,          -- A171..A174
    dependents               SMALLINT,
    telephone                TEXT,          -- A191..A192
    foreign_worker           TEXT,          -- A201..A202
    credit_risk_class        SMALLINT     NOT NULL CHECK (credit_risk_class IN (1,2)),
    source                   TEXT         NOT NULL DEFAULT 'uci-144',
    loaded_at                TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE credit_risk.german_credit IS
    'UCI 144. Grain: one row per loan applicant. Target: credit_risk_class (1 good, 2 bad).';

-- ---------------------------------------------------------------------------
-- Privileges. loaded_at exists on both tables because dbt source freshness
-- cannot be configured without a timestamp column to measure.
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA credit_risk TO gama;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA credit_risk TO gama;
ALTER DEFAULT PRIVILEGES FOR ROLE gama IN SCHEMA credit_risk
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO gama;
