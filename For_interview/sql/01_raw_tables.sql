-- Raw tables for the disposable garment_lab database.
-- Generated from For_interview/garment_supply_chain_lab.md, section 6.
--
-- Run as app_garment, NOT as postgres -- ownership does not cascade from a
-- schema to objects created inside it later, and TRUNCATE ... RESTART
-- IDENTITY needs ownership.
--
--   psql -U app_garment -h 192.168.1.71 -d garment_lab -f sql/01_raw_tables.sql

-- =====================================================================
-- mfg_raw -- garment factory floor. Source: UCI 597.
-- =====================================================================

-- Types follow the observed ranges of the source CSV:
--   no_of_workers reaches 30.5 -- teams are shared, so it is NOT an integer
--   actual_productivity reaches 1.1204375 -- teams can beat target, so this
--     is not a 0..1 fraction and must not be constrained to one
--   wip is NULL on all 506 finishing rows -- work-in-progress is a sewing
--     concept only, so the NULL is meaningful, not missing data
CREATE TABLE mfg_raw.production_log (
    record_id              INTEGER       PRIMARY KEY,
    work_date              DATE          NOT NULL,
    quarter                TEXT          NOT NULL,
    department             TEXT          NOT NULL,
    day_name               TEXT          NOT NULL,
    team                   SMALLINT      NOT NULL,
    targeted_productivity  NUMERIC(4,2)  NOT NULL,
    smv                    NUMERIC(6,2)  NOT NULL,
    wip                    INTEGER,
    over_time              INTEGER       NOT NULL,
    incentive              INTEGER       NOT NULL,
    idle_time              NUMERIC(6,1)  NOT NULL,
    idle_men               SMALLINT      NOT NULL,
    no_of_style_change     SMALLINT      NOT NULL,
    no_of_workers          NUMERIC(5,1)  NOT NULL,
    actual_productivity    NUMERIC(12,9) NOT NULL,
    source                 TEXT          NOT NULL DEFAULT 'uci_597',
    loaded_at              TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- (work_date, team, trim(department)) is the real natural key: 1,197 rows,
-- 1,197 distinct combinations, verified. Declared as an expression index so
-- the trailing space in 'finishing ' cannot create a phantom duplicate.
CREATE UNIQUE INDEX production_log_natural_key
    ON mfg_raw.production_log (work_date, team, trim(department));

-- =====================================================================
-- dist_raw -- downstream orders. Source: DataCo, Apparel department only.
-- =====================================================================

CREATE TABLE dist_raw.categories (
    category_id      INTEGER PRIMARY KEY,
    category_name    TEXT NOT NULL,
    department_id    INTEGER NOT NULL,
    department_name  TEXT NOT NULL,
    source           TEXT NOT NULL DEFAULT 'dataco',
    loaded_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Money columns are unconstrained NUMERIC on purpose. The upstream values
-- are float32 artefacts ('59.99000168', '461.480011') with inconsistent
-- scale; pinning NUMERIC(p,s) here just produces "numeric field overflow"
-- on load. Rounding to business precision is the staging layer's job.
CREATE TABLE dist_raw.products (
    product_card_id  INTEGER PRIMARY KEY,
    product_name     TEXT NOT NULL,
    category_id      INTEGER NOT NULL REFERENCES dist_raw.categories (category_id),
    product_price    NUMERIC NOT NULL,
    product_status   SMALLINT NOT NULL,
    source           TEXT NOT NULL DEFAULT 'dataco',
    loaded_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- zipcode is TEXT, not INTEGER: US ZIPs are identifiers, not quantities,
-- and Puerto Rico's start 006xx. (Upstream already stripped those leading
-- zeros -- '00603' arrives as '603' -- so TEXT preserves what is left
-- rather than compounding the loss.)
CREATE TABLE dist_raw.customers (
    customer_id  INTEGER PRIMARY KEY,
    first_name   TEXT,
    last_name    TEXT,
    segment      TEXT NOT NULL,
    city         TEXT,
    state        TEXT,
    country      TEXT,
    zipcode      TEXT,
    street       TEXT,
    latitude     NUMERIC,
    longitude    NUMERIC,
    source       TEXT NOT NULL DEFAULT 'dataco',
    loaded_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE dist_raw.orders (
    order_id             INTEGER PRIMARY KEY,
    customer_id          INTEGER NOT NULL REFERENCES dist_raw.customers (customer_id),
    order_date           TIMESTAMP NOT NULL,
    shipping_date        TIMESTAMP NOT NULL,
    order_status         TEXT NOT NULL,
    delivery_status      TEXT NOT NULL,
    late_delivery_risk   SMALLINT NOT NULL,
    days_shipping_real   SMALLINT NOT NULL,
    days_shipping_sched  SMALLINT NOT NULL,
    shipping_mode        TEXT NOT NULL,
    order_type           TEXT NOT NULL,
    market               TEXT NOT NULL,
    order_region         TEXT NOT NULL,
    order_country        TEXT NOT NULL,
    order_state          TEXT,
    order_city           TEXT,
    order_zipcode        TEXT,
    source               TEXT NOT NULL DEFAULT 'dataco',
    loaded_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX orders_order_date_idx ON dist_raw.orders (order_date);
CREATE INDEX orders_customer_idx   ON dist_raw.orders (customer_id);

CREATE TABLE dist_raw.order_items (
    order_item_id      INTEGER PRIMARY KEY,
    order_id           INTEGER NOT NULL REFERENCES dist_raw.orders (order_id),
    product_card_id    INTEGER NOT NULL REFERENCES dist_raw.products (product_card_id),
    quantity           SMALLINT NOT NULL,
    item_price         NUMERIC NOT NULL,
    discount           NUMERIC NOT NULL,
    discount_rate      NUMERIC NOT NULL,
    sales              NUMERIC NOT NULL,
    item_total         NUMERIC NOT NULL,
    profit_ratio       NUMERIC NOT NULL,
    benefit_per_order  NUMERIC NOT NULL,
    source             TEXT NOT NULL DEFAULT 'dataco',
    loaded_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX order_items_order_idx   ON dist_raw.order_items (order_id);
CREATE INDEX order_items_product_idx ON dist_raw.order_items (product_card_id);

-- =====================================================================
-- The bridge. Created LAST because its foreign key points at
-- dist_raw.categories, which must exist first.
-- =====================================================================

-- AUTHORED, not source data -- see §9. The two sources share no natural
-- key, so this table is the join. The category_id values are the REAL
-- DataCo ids, which is what lets the foreign key below be a real one
-- rather than a decorative column.
CREATE TABLE mfg_raw.team_product_line (
    team           SMALLINT PRIMARY KEY,
    category_id    INTEGER  NOT NULL REFERENCES dist_raw.categories (category_id),
    category_name  TEXT     NOT NULL,
    product_line   TEXT     NOT NULL,
    source         TEXT     NOT NULL DEFAULT 'authored',
    loaded_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
