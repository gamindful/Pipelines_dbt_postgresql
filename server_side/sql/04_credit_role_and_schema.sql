-- Run as the postgres superuser, connected to the credit_risk database.
--   psql -U postgres -d credit_risk -v app_password=... -f 04_credit_role_and_schema.sql
--
-- Creates the app role, the raw landing schema, the dbt target schema, and
-- the two source tables. Password comes from the :app_password psql variable
-- so it never appears in this file.

CREATE ROLE app_credit WITH LOGIN PASSWORD :'app_password';

CREATE SCHEMA IF NOT EXISTS credit_raw  AUTHORIZATION app_credit;
CREATE SCHEMA IF NOT EXISTS analytics   AUTHORIZATION app_credit;

GRANT CONNECT ON DATABASE credit_risk TO app_credit;
GRANT USAGE, CREATE ON SCHEMA credit_raw, analytics TO app_credit;
ALTER ROLE app_credit SET search_path = credit_raw, analytics, public;

SET search_path = credit_raw;

-- ---------------------------------------------------------------------------
-- UCI "Default of Credit Card Clients" (Taiwan, 2005). 30,000 rows.
-- Distributed as .xls with TWO header rows -- the real column names are on
-- the second row. Column meanings per the UCI dataset documentation.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS credit_raw.credit_default (
    client_id           INTEGER PRIMARY KEY,
    limit_bal           NUMERIC(14,2) NOT NULL,
    sex                 SMALLINT      NOT NULL,   -- 1 = male, 2 = female
    education           SMALLINT      NOT NULL,   -- 1 grad .. 4 other
    marriage            SMALLINT      NOT NULL,   -- 1 married, 2 single, 3 other
    age                 SMALLINT      NOT NULL CHECK (age BETWEEN 0 AND 130),
    pay_0               SMALLINT,                 -- repayment status, months -1..-6
    pay_2               SMALLINT,
    pay_3               SMALLINT,
    pay_4               SMALLINT,
    pay_5               SMALLINT,
    pay_6               SMALLINT,
    bill_amt1           NUMERIC(14,2),            -- bill statement amounts
    bill_amt2           NUMERIC(14,2),
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
    ON credit_raw.credit_default (default_next_month);

-- ---------------------------------------------------------------------------
-- UCI "Statlog German Credit". 1,000 rows.
-- The source file has NO header and is space-delimited. Categorical columns
-- are coded (A11, A34, ...); the codebook ships as german.doc inside the zip.
-- Names below follow that documentation -- verify against german.doc before
-- relying on the semantics.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS credit_raw.german_credit (
    applicant_id             SERIAL PRIMARY KEY,
    checking_status          TEXT,        -- A11..A14
    duration_months          SMALLINT,
    credit_history           TEXT,        -- A30..A34
    purpose                  TEXT,        -- A40..A410
    credit_amount            NUMERIC(12,2),
    savings_status           TEXT,        -- A61..A65
    employment_since         TEXT,        -- A71..A75
    installment_rate         SMALLINT,
    personal_status_sex      TEXT,        -- A91..A95
    other_debtors            TEXT,        -- A101..A103
    residence_since          SMALLINT,
    property_type            TEXT,        -- A121..A124
    age_years                SMALLINT,
    other_installment_plans  TEXT,        -- A141..A143
    housing                  TEXT,        -- A151..A153
    existing_credits         SMALLINT,
    job                      TEXT,        -- A171..A174
    dependents               SMALLINT,
    telephone                TEXT,        -- A191..A192
    foreign_worker           TEXT,        -- A201..A202
    credit_risk_class        SMALLINT NOT NULL CHECK (credit_risk_class IN (1,2)),  -- 1 good, 2 bad
    source                   TEXT        NOT NULL DEFAULT 'uci-144',
    loaded_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Tables (and german_credit's SERIAL sequence) were created while connected
-- as postgres, so postgres owns them even though the schema itself says
-- AUTHORIZATION app_credit -- ownership does not cascade from schema to the
-- objects created inside it. TRUNCATE ... RESTART IDENTITY needs sequence
-- OWNERSHIP, not just USAGE, so transfer both explicitly.
ALTER TABLE credit_raw.credit_default OWNER TO app_credit;
ALTER TABLE credit_raw.german_credit  OWNER TO app_credit;
ALTER SEQUENCE credit_raw.german_credit_applicant_id_seq OWNER TO app_credit;

-- TRUNCATE is included because load_credit_data.py --truncate uses it to
-- make reruns idempotent (client_id/applicant_id would otherwise collide
-- with existing rows on a second load).
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA credit_raw TO app_credit;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA credit_raw TO app_credit;
ALTER DEFAULT PRIVILEGES FOR ROLE app_credit IN SCHEMA credit_raw
    GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO app_credit;
