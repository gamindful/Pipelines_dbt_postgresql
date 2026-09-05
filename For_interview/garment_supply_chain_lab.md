# Disposable lab: garment supply chain

A throwaway PostgreSQL database on `192.168.1.71`, loaded with two real
supply-chain datasets, modelled with dbt, and queryable from Power BI or
Tableau — built so the whole thing can be destroyed with one statement when
the interview is over.

**Nothing in this file has been executed against your server.** Every command
is written to be run by you, in order. Where a step is known to behave
differently on this particular machine (Spanish locale, `psql` off `PATH`,
`NT AUTHORITY\NetworkService` service account), that is called out inline —
those notes come from `database.md` and `server_side/datasets/README.md`,
which document problems already hit on this exact server.

---

## Contents

| # | Step | Runs on | Needs superuser |
|---|---|---|---|
| 0 | [Design](#0--design) | — | — |
| 1 | [Prerequisites](#1--prerequisites) | both | — |
| 2 | [Create the role](#2--create-the-role) | server | yes |
| 3 | [Create the database](#3--create-the-database) | server | yes |
| 4 | [Create the schemas and grants](#4--create-the-schemas-and-grants) | server | yes |
| 5 | [Add the dbt profile](#5--add-the-dbt-profile) | client | no |
| 6 | [Create the raw tables](#6--create-the-raw-tables) | either | no |
| 7 | [Load the CSVs](#7--load-the-csvs) | client | no |
| 8 | [Verify the load](#8--verify-the-load) | either | no |
| 9 | [The dataset](#9--the-dataset) | — | — |
| 10 | [dbt concepts](#10--dbt-concepts) | — | — |
| 11 | [Build the dbt project](#11--build-the-dbt-project) | client | no |
| 12 | [Export CSV for Power BI / Tableau](#12--export-csv-for-power-bi--tableau) | client | no |
| 13 | [SQL exercises](#13--sql-exercises) | either | no |
| 14 | [Teardown](#14--teardown) | server | yes |
| 15 | [Troubleshooting](#15--troubleshooting) | — | — |

---

## 0 — Design

```
garment_lab                       ← one disposable database
├─ mfg_raw       factory floor production   created by psql, written by \copy
├─ dist_raw      orders / customers / SKUs  created by psql, written by \copy
├─ staging       dbt-owned
├─ intermediate  dbt-owned
└─ marts         dbt-owned
```

Two ideas carried over from `database.md`, both worth keeping:

- **Raw schemas are created by hand and written only by loaders. dbt owns
  `staging`, `intermediate` and `marts`.** A bad `dbt run` then cannot destroy
  ingested source data — the worst case is a dropped view in a dbt schema,
  which `dbt run` rebuilds.
- **One database, many schemas.** PostgreSQL has no cross-*database*
  references, and a dbt project connects to exactly one database. Crossing
  schemas is free; crossing databases is impossible. That is the whole reason
  `mfg_raw` and `dist_raw` are schemas here and not separate databases — and
  it is what makes the cross-schema joins in [§13](#13--sql-exercises)
  possible at all.

### What "disposable" changes

`analytics_lab` in `database.md` sits on a dedicated tablespace, which means
tearing it down is a `DROP DATABASE`, then a `DROP TABLESPACE`, then cleaning
up a folder and its ACL. **This lab deliberately uses no tablespace.** It
lands in the default `pg_default`, so teardown is:

```sql
DROP DATABASE garment_lab;
DROP ROLE app_garment;
```

Two statements, no filesystem residue, no `icacls` grant to reapply. That is
the only structural difference from the permanent project, and it is the
right trade: a tablespace buys you I/O placement control you do not need for
a database you intend to delete.

### Objects this guide creates

| Object | Name | Created in |
|---|---|---|
| Role | `app_garment` | [§2](#2--create-the-role) |
| Database | `garment_lab` | [§3](#3--create-the-database) |
| Raw schemas | `mfg_raw`, `dist_raw` | [§4](#4--create-the-schemas-and-grants) |
| dbt schemas | `staging`, `intermediate`, `marts` | dbt, on first run |
| Raw tables | 7 (2 in `mfg_raw`, 5 in `dist_raw`) | [§6](#6--create-the-raw-tables) |
| Profile | `garment_lab` in `~/.dbt/profiles.yml` | [§5](#5--add-the-dbt-profile) |

---

## 1 — Prerequisites

### On the server (Windows, `192.168.1.71`)

`psql` is at `C:\Program Files\PostgreSQL\18\bin\psql.exe` and is **not** on
`PATH`. Every server-side block below starts by setting `$pgbin` so the full
path is used.

You need the `postgres` superuser password. Set it once per PowerShell
window so each `psql` call does not prompt:

```powershell
$pgbin = "C:\Program Files\PostgreSQL\18\bin"
$env:PGPASSWORD = "<postgres password>"
```

> Skipping `$env:PGPASSWORD` makes `psql` prompt interactively. In some
> terminals that prompt is easy to miss, and it looks like an authentication
> failure even when the password would have been correct.

Clear it when you are done with the superuser steps:

```powershell
Remove-Item Env:\PGPASSWORD
```

### On the client (macOS)

`psql` for the client-side `\copy` load, and the project venv for dbt:

```bash
which psql || brew install postgresql@16
```

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && ./venv/bin/dbt --version
```

That must report `Core:` — if it reports `dbt-fusion`, a bare `dbt` on
`PATH` is shadowing the venv. Fusion has no Postgres adapter. Always call
`./venv/bin/dbt` explicitly, as this project already does everywhere else.

### The data

Already prepared, in this folder:

```
For_interview/datasets/garment_supply_chain/
├── prepare_datasets.py      rebuilds everything below from the two sources
├── _source/                 upstream files, untouched
├── mfg/
│   ├── production_log.csv       1,197 rows
│   └── team_product_line.csv       12 rows   ← authored, see §9
└── dist/
    ├── customers.csv           13,785 rows
    ├── categories.csv               7 rows
    ├── products.csv                 8 rows
    ├── orders.csv              35,190 rows
    └── order_items.csv         48,998 rows
```

To rebuild from scratch (re-downloads ~96 MB):

```bash
python3 prepare_datasets.py --download
```

---

## 2 — Create the role

The application role owns everything in the lab. dbt connects as this role,
never as `postgres`.

### Generate a password

```powershell
$pw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | % {[char]$_}); $pw
```

Copy the output — it is needed here and again in [§5](#5--add-the-dbt-profile).

### Create it

> **Use `-f`, not `-c`.** On this Windows / psql 18 setup, `:'var'`
> interpolation silently fails when the SQL arrives as a `-c` argument — the
> colon reaches the parser unsubstituted and you get `syntax error at or
> near ":"` (or its Spanish spelling, `error de sintaxis en o cerca de «:»`).
> The identical text read from a file with `-f` works. This is documented in
> `database.md` §5 and confirmed with a minimal `SELECT :app_password;` test.
> Passing it this way also keeps the password out of the `.sql` file — only
> the variable *reference* is ever written to disk.

```powershell
@'
CREATE ROLE app_garment WITH LOGIN PASSWORD :'app_password';
'@ | Out-File -Encoding utf8 "$env:TEMP\create_garment_role.sql"

& "$pgbin\psql.exe" -U postgres -h 127.0.0.1 -d postgres -v app_password="$pw" -f "$env:TEMP\create_garment_role.sql"

Remove-Item "$env:TEMP\create_garment_role.sql"
```

`CREATE ROLE` is cluster-wide, not per-database — that is why this runs
against `postgres` and why teardown in [§14](#14--teardown) has to drop the
role separately from the database.

---

## 3 — Create the database

Connect to `postgres`; `garment_lab` does not exist yet. `CREATE DATABASE`
cannot run inside a transaction block, which is why it gets its own `-c`.

```powershell
& "$pgbin\psql.exe" -U postgres -h 127.0.0.1 -d postgres -c "CREATE DATABASE garment_lab WITH OWNER = app_garment ENCODING = 'UTF8';"
```

`OWNER = app_garment` is what makes this disposable-friendly: the owner can
create schemas without extra grants, and `DROP DATABASE` later removes every
object inside it in one statement.

No `TABLESPACE` clause — see [§0](#what-disposable-changes).

---

## 4 — Create the schemas and grants

```powershell
& "$pgbin\psql.exe" -U postgres -h 127.0.0.1 -d garment_lab `
  -c "CREATE SCHEMA mfg_raw  AUTHORIZATION app_garment;" `
  -c "CREATE SCHEMA dist_raw AUTHORIZATION app_garment;" `
  -c "GRANT CREATE ON DATABASE garment_lab TO app_garment;" `
  -c "ALTER ROLE app_garment SET search_path = mfg_raw, dist_raw, staging, marts, public;"
```

`GRANT CREATE ON DATABASE` is what lets dbt create `staging`,
`intermediate` and `marts` on its first run. Without it dbt fails with
`permission denied for database garment_lab` at the point it tries to
materialise the first model.

> **Ownership does not cascade from a schema to objects created inside it
> later.** `AUTHORIZATION app_garment` sets the *schema's* owner. If you
> create the tables in [§6](#6--create-the-raw-tables) while connected as
> `postgres`, `postgres` owns those tables — and `TRUNCATE ... RESTART
> IDENTITY` then fails with `must be owner of sequence`. This bit the
> `credit_risk` build (`server_side/datasets/README.md`, Method 2, bug 3).
> **Avoid it entirely by running §6 as `app_garment`**, which is how the
> commands there are written.

Verify — two schemas, both owned by `app_garment`:

```powershell
& "$pgbin\psql.exe" -U postgres -h 127.0.0.1 -d garment_lab -c "\dn+" -c "\du app_garment"
```

You can release the superuser session now:

```powershell
Remove-Item Env:\PGPASSWORD
```

Everything from here runs as `app_garment`.

---

## 5 — Add the dbt profile

On the **client** (macOS). This file lives outside the repository and is
never committed — `profiles.yml` is already in `.gitignore`.

```bash
cat >> ~/.dbt/profiles.yml <<'EOF'

garment_lab:
  target: dev
  outputs:
    dev:
      type: postgres
      host: 192.168.1.71
      port: 5432
      user: app_garment
      pass: '<password-from-step-2>'
      dbname: garment_lab
      schema: staging
      threads: 4
      connect_timeout: 5
EOF
```

Two things people get wrong here:

- **`schema:` is dbt's default target for models, not where sources live.**
  Sources are named explicitly in `_sources.yml` ([§11](#11--build-the-dbt-project)).
  Setting `schema: staging` only means "a model with no `+schema` config
  materialises into `staging`".
- **`profile:` in `dbt_project.yml` selects which block above is used.**
  Your `dbt_project.yml` currently says `profile: 'analytics_lab'`. Point it
  at this lab when you want to work on it:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && sed -i '' "s/^profile: .*/profile: 'garment_lab'/" dbt_project.yml
```

Then confirm the connection before going further:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && ./venv/bin/dbt debug
```

`All checks passed!` means the database exists and dbt can reach it.

---

## 6 — Create the raw tables

Run as `app_garment` so it owns the tables — see the ownership warning in
[§4](#4--create-the-schemas-and-grants).

Save this as `ddl_garment_lab.sql` (a copy is already at
`For_interview/sql/01_raw_tables.sql`):

```sql
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
```

Run it from the client:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && PGPASSWORD='<password-from-step-2>' psql -U app_garment -h 192.168.1.71 -d garment_lab -f For_interview/sql/01_raw_tables.sql
```

Every raw table carries `loaded_at TIMESTAMPTZ NOT NULL DEFAULT now()`.
That column is not decoration: **`dbt source freshness` cannot be configured
at all without it**, and the `_sources.yml` in [§11](#11--build-the-dbt-project)
depends on it.

---

## 7 — Load the CSVs

`\copy` is a **psql meta-command**. It runs client-side: it reads the CSV
from whichever machine is running `psql` and streams it over the existing
connection. Server-side `COPY '<path>'` reads a path on the *server's*
filesystem and needs superuser or `pg_write_server_files` — `\copy` needs
neither. Since the CSVs are on your Mac, `\copy` from the Mac is the path of
least resistance.

### Two things that will bite you

**1. Column lists are mandatory.** Every table has `source` and `loaded_at`
columns the CSVs do not carry. Without an explicit column list, `\copy`
expects the CSV to match the table's full column count and order, and fails
immediately.

**2. `SET datestyle` first.** The dates arrive as `1/1/2015` and
`2/24/2016 13:57` — month-first, ambiguous. If the server's `DateStyle` is
`DMY`, `2/24/2016` is rejected outright (`date/time field value out of
range`) while `1/2/2015` silently loads as 2 January instead of 1 February.
Setting it explicitly in the same session removes the guesswork. **This is
why the load must be a single `-f` script, not a series of `-c` flags** —
one file is unambiguously one session.

Save as `For_interview/sql/02_load.sql` (already written there):

```sql
SET datestyle = 'ISO, MDY';

\copy mfg_raw.production_log (record_id, work_date, quarter, department, day_name, team, targeted_productivity, smv, wip, over_time, incentive, idle_time, idle_men, no_of_style_change, no_of_workers, actual_productivity) FROM 'mfg/production_log.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.categories (category_id, category_name, department_id, department_name) FROM 'dist/categories.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.products (product_card_id, product_name, category_id, product_price, product_status) FROM 'dist/products.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.customers (customer_id, first_name, last_name, segment, city, state, country, zipcode, street, latitude, longitude) FROM 'dist/customers.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.orders (order_id, customer_id, order_date, shipping_date, order_status, delivery_status, late_delivery_risk, days_shipping_real, days_shipping_sched, shipping_mode, order_type, market, order_region, order_country, order_state, order_city, order_zipcode) FROM 'dist/orders.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.order_items (order_item_id, order_id, product_card_id, quantity, item_price, discount, discount_rate, sales, item_total, profit_ratio, benefit_per_order) FROM 'dist/order_items.csv' WITH (FORMAT csv, HEADER true)

-- Last: its category_id is a foreign key into dist_raw.categories.
\copy mfg_raw.team_product_line (team, category_id, category_name, product_line) FROM 'mfg/team_product_line.csv' WITH (FORMAT csv, HEADER true)
```

**Order matters.** `products` references `categories`, `orders` references
`customers`, `order_items` references both, and `team_product_line`
references `categories` — which is why the bridge loads last, after the
schema it points into. Loading out of order trips the foreign keys.

The paths are **relative**, so run `psql` from the datasets directory. That
keeps the script portable across machines instead of hard-coding
`/Users/gamaliel/...` into a tracked file:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql/For_interview/datasets/garment_supply_chain && PGPASSWORD='<password-from-step-2>' psql -U app_garment -h 192.168.1.71 -d garment_lab -f ../../sql/02_load.sql
```

Expect seven `COPY <n>` lines. Empty unquoted CSV fields become `NULL`
(that is psql's CSV default), which is what makes `wip` land as `NULL` on
the 506 finishing rows rather than as an empty string.

### Re-running

`\copy` appends. To reload without duplicating, truncate first — children
before parents, or use `CASCADE`:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql/For_interview/datasets/garment_supply_chain && PGPASSWORD='<password-from-step-2>' psql -U app_garment -h 192.168.1.71 -d garment_lab -c "TRUNCATE mfg_raw.production_log, mfg_raw.team_product_line, dist_raw.order_items, dist_raw.orders, dist_raw.customers, dist_raw.products, dist_raw.categories;"
```

This works because `app_garment` owns the tables ([§4](#4--create-the-schemas-and-grants)).
If it errors with `must be owner of` / `debe ser dueño de`, the tables were
created as `postgres` — fix with `ALTER TABLE ... OWNER TO app_garment`.

---

## 8 — Verify the load

```sql
SELECT 'mfg_raw.production_log'   AS table_name, count(*) FROM mfg_raw.production_log
UNION ALL SELECT 'mfg_raw.team_product_line', count(*) FROM mfg_raw.team_product_line
UNION ALL SELECT 'dist_raw.categories',       count(*) FROM dist_raw.categories
UNION ALL SELECT 'dist_raw.products',         count(*) FROM dist_raw.products
UNION ALL SELECT 'dist_raw.customers',        count(*) FROM dist_raw.customers
UNION ALL SELECT 'dist_raw.orders',           count(*) FROM dist_raw.orders
UNION ALL SELECT 'dist_raw.order_items',      count(*) FROM dist_raw.order_items;
```

| table | expected |
|---|---|
| `mfg_raw.production_log` | 1,197 |
| `mfg_raw.team_product_line` | 12 |
| `dist_raw.categories` | 7 |
| `dist_raw.products` | 8 |
| `dist_raw.customers` | 13,785 |
| `dist_raw.orders` | 35,190 |
| `dist_raw.order_items` | 48,998 |

Then confirm the dates parsed as **month-first**. If `SET datestyle` did not
take, this returns the wrong range and everything downstream is quietly
wrong:

```sql
SELECT min(work_date), max(work_date) FROM mfg_raw.production_log;
-- expect 2015-01-01 .. 2015-03-11

SELECT min(order_date), max(order_date) FROM dist_raw.orders;
-- expect 2015-01-01 00:21:00 .. 2018-01-31 22:35:00
```

And confirm the overlap the cross-schema exercises depend on:

```sql
SELECT count(*) AS orders_in_factory_window
FROM dist_raw.orders
WHERE order_date >= DATE '2015-01-01'
  AND order_date <  DATE '2015-03-12';
-- expect 2,262
```

---

## 9 — The dataset

Two independent public datasets, stitched into one supply chain: a garment
factory upstream, an apparel distributor downstream.

| | Upstream (`mfg_raw`) | Downstream (`dist_raw`) |
|---|---|---|
| **Source** | UCI ML Repository #597 | Mendeley Data, DOI `10.17632/8gx2fvg2k6.5` |
| **Name** | Productivity Prediction of Garment Employees | DataCo Smart Supply Chain |
| **Authors** | Imran, Amin, Islam Bhuiyan, Rifat | Constante, Silva, Pereira |
| **Licence** | CC BY 4.0 | CC BY 4.0 |
| **Grain** | one row per team, per department, per day | one row per order line |
| **Period** | 2015-01-01 → 2015-03-11 | 2015-01-01 → 2018-01-31 |
| **Scope here** | all 1,197 rows | Apparel department only, 48,998 lines |

They overlap for **59 working days** in Q1 2015 — 2,262 orders and 3,236
order lines land inside the factory's window. That overlap is what makes
[§13](#13--sql-exercises)'s cross-schema exercises return real rows instead
of an empty set.

### `mfg_raw.production_log` — the factory floor

Real production records from a Bangladeshi garment manufacturer. Each row is
one team's output for one day in one department, against a target set by
industrial engineering.

| Column | Meaning |
|---|---|
| `work_date` | production date |
| `quarter` | **week-of-month**, not calendar quarter — `Quarter1`..`Quarter5` |
| `department` | `sweing` or `finishing` (see dirt, below) |
| `day_name` | day of week — **no Friday**, the weekend in Bangladesh |
| `team` | 1–12 |
| `targeted_productivity` | target set for that team/day, 0.07–0.80 |
| `actual_productivity` | achieved, 0.234–**1.120** |
| `smv` | Standard Minute Value — allotted minutes per garment |
| `wip` | work in progress, unfinished items — **sewing only** |
| `over_time` | overtime, minutes |
| `incentive` | financial incentive, BDT |
| `idle_time` / `idle_men` | production stoppage, and workers idled by it |
| `no_of_style_change` | garment style changes that day, 0–2 |
| `no_of_workers` | workers on the team — **fractional** (30.5) |

**The dirt is the point.** Every one of these is a real defect in the source
and each one is a staging-layer exercise:

| Problem | Detail | Fixed in |
|---|---|---|
| `sweing` | misspelling of "sewing", in the source | `stg_mfg__production_log` |
| `'finishing '` | 257 rows with a **trailing space**, 249 without — 3 distinct values for 2 departments | same |
| `wip` NULL | all 506 finishing rows; WIP is a sewing concept, so this is *meaningful*, not missing | kept NULL |
| `quarter` | `Quarter5` exists — it is week-of-month, and the name misleads | renamed `week_of_month` |
| `actual_productivity` > 1 | teams beat target; do **not** clamp to 1.0 | left alone |
| `no_of_workers` = 30.5 | teams split across lines; not an integer | `NUMERIC(5,1)` |

The trailing-space one is the single most valuable thing here: `GROUP BY
department` returns **three** groups for two real departments, and nothing
in the output looks wrong. It is exactly the class of bug a staging layer
exists to catch.

### `dist_raw.*` — the distributor

DataCo's flat 53-column export, filtered to `Department Name = 'Apparel'`
and **normalised into five tables**. The functional dependencies were
verified first — 0 orders and 0 customers had conflicting attributes across
their rows — so the split is lossless.

```
customers ──< orders ──< order_items >── products >── categories
```

| Table | Rows | Grain |
|---|---|---|
| `customers` | 13,785 | one per customer |
| `categories` | 7 | one per product category |
| `products` | 8 | one per SKU |
| `orders` | 35,190 | one per order |
| `order_items` | 48,998 | one per order line |

Columns worth knowing before writing queries:

| Column | Note |
|---|---|
| `orders.late_delivery_risk` | 0/1 flag — `days_shipping_real > days_shipping_sched` |
| `orders.delivery_status` | `Advance shipping`, `On time`, `Late delivery`, `Shipping canceled` |
| `orders.order_status` | 9 values incl. `SUSPECTED_FRAUD`, `CANCELED` — **filter these out of revenue** |
| `order_items.sales` | gross, **before** discount |
| `order_items.item_total` | net, **after** discount — this is the revenue column |
| `order_items.profit_ratio` | goes as low as **−2.75**; losses are real, not errors |
| `order_items.benefit_per_order` | profit in currency; min −1,027.25 |

Three quirks to expect:

- **Category labels are noisy.** The two biggest Apparel categories are
  `Cleats` (24,551 lines) and `Men's Footwear` (22,246) — footwear filed
  under Apparel. `Total Gym 1400`, an exercise machine, sits in `Cleats`.
  The mislabelling is upstream and genuine; leave it and describe it, or
  regroup it in a mart, but do not pretend it is not there.
- **`Baby ` has a trailing space** — same class of bug as `finishing `,
  now in a different source system.
- **Only 8 distinct SKUs** across 48,998 lines. The product dimension is
  tiny; the analytical interest is in customers, geography, and time.

Dropped during normalisation, and why: `Customer Email` and `Customer
Password` (masked placeholders upstream — no reason to put either in a
portfolio database), `Product Description` (empty on all 48,998 rows), and
`Order Profit Per Order` (byte-identical to `Benefit per order` on every
row).

### `mfg_raw.team_product_line` — the bridge, and it is authored

**This table is not source data. I wrote it.** The two datasets come from
unrelated companies and share no key — no join between them exists in
nature.

It maps each of the 12 factory teams to the category it supplies:

| team | category_id | category_name | product_line |
|---|---|---|---|
| 1, 3 | 17 | Cleats | footwear |
| 2, 8 | 18 | Men's Footwear | footwear |
| 4, 7 | 76 | Women's Clothing | apparel |
| 5, 10 | 70 | Men's Clothing | apparel |
| 6, 12 | 63 | Children's Clothing | apparel |
| 9 | 60 | `Baby ` | apparel |
| 11 | 66 | Crafts | accessories |

The `category_id` values are the **real** DataCo ids, so the table carries a
genuine foreign key into `dist_raw.categories` and the joins are structurally
sound. The *assignment* of teams to categories is invented.

Two reasons this is the right move rather than a cheat:

1. It is what the job actually is. Two source systems that must be reported
   on together, with no shared key, get a conformed dimension — hand-built,
   version-controlled, owned by the analytics team. This is a small honest
   example of that.
2. Without it there is no cross-schema join to practise, which is half of
   what you asked for.

**Say so out loud if you present this.** "The bridge is synthetic; the
sources share no key" is a good answer that shows you know what a conformed
dimension is. Being caught not mentioning it is a bad one. It is labelled in
`prepare_datasets.py`, in the DDL, and in the model that consumes it.

### Rebuilding

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql/For_interview/datasets/garment_supply_chain && python3 prepare_datasets.py --download
```

The 96 MB DataCo source is git-ignored; everything else is small enough to
track. Attribution, as CC BY 4.0 requires:

- Imran, A. A., Amin, M. N., Islam Bhuiyan, M. R., Rifat, M. R. I.
  *Productivity Prediction of Garment Employees*. UCI Machine Learning
  Repository, 2020. <https://doi.org/10.24432/C51S6D>
- Constante, F., Silva, F., Pereira, A. *DataCo Smart Supply Chain for Big
  Data Analysis*. Mendeley Data V5, 2019.
  <https://doi.org/10.17632/8gx2fvg2k6.5>

---

## 10 — dbt concepts

What each piece is, and what it is for **in this project specifically**.

### The one-sentence version

dbt is `SELECT` statements plus a dependency graph. You write a query; dbt
wraps it in `CREATE VIEW` / `CREATE TABLE`, figures out what must run first,
and runs it. Everything below is in service of that.

### Model

**One `.sql` file = one `SELECT` = one object in the database.** No DDL, no
`CREATE`, no `INSERT` — dbt writes those. The filename becomes the object
name.

```sql
-- models/garment_supply_chain/staging/stg_dist__products.sql
select
    product_card_id,
    product_name,
    category_id,
    round(product_price, 2) as product_price
from {{ source('dist_raw', 'products') }}
```

Models are layered, and the layering is the actual design:

| Layer | Materialised | Job | Rule |
|---|---|---|---|
| **staging** | `view` | one model per source table: rename, cast, clean | no joins, no aggregation |
| **intermediate** | `ephemeral` | the joins and business logic nobody should repeat | not exposed to BI |
| **marts** | `table` | what a person or a dashboard queries | one grain per model, stated |

Why those materialisations: staging views cost nothing and always reflect
raw; ephemeral intermediates are inlined as CTEs and create no database
object, so logic is defined once without cluttering the schema; marts are
tables because BI tools query them repeatedly and should not recompute the
graph each time.

### `ref()` and `source()`

The two functions that build the DAG.

- `{{ source('dist_raw', 'orders') }}` → a table dbt **does not** manage,
  declared in `_sources.yml`. Compiles to `dist_raw.orders`.
- `{{ ref('stg_dist__orders') }}` → another **model**. Compiles to
  `staging.stg_dist__orders`.

Never hard-code a table name. `ref()` is what tells dbt the build order and
what makes `dbt run --select +fct_order_lines` know to build the four models
upstream of it first.

### Source

Declares raw tables so dbt can reference, document, test and freshness-check
them:

```yaml
sources:
  - name: dist_raw
    schema: dist_raw
    loaded_at_field: loaded_at
    freshness:
      warn_after: {count: 30, period: day}
    tables:
      - name: orders
```

`loaded_at_field` is why every raw table in [§6](#6--create-the-raw-tables)
has a `loaded_at` column — `dbt source freshness` cannot run without it.

### Macro

A Jinja function. Use one when the same SQL fragment appears in more than
one model, or when you need logic SQL cannot express.

This project already ships the important one, `macros/generate_schema_name.sql`.
It overrides dbt's default behaviour of *concatenating* the target schema
with the model's `+schema` config (profile `staging` + config `marts` →
`staging_marts`), so that `+schema: marts` produces exactly `marts`. Without
it, this lab's schema names come out wrong.

A domain macro worth adding here:

```sql
{% macro on_time_flag(real_days, sched_days) %}
    case
        when {{ real_days }} is null or {{ sched_days }} is null then null
        when {{ real_days }} <= {{ sched_days }} then true
        else false
    end
{% endmacro %}
```

Used as `{{ on_time_flag('days_shipping_real', 'days_shipping_sched') }}`.
The value is that "on time" is now defined in exactly one place — when
someone argues same-day should count differently, you change one file.

### Test

Assertions that run against built models. Two kinds:

**Generic** — declared in YAML, reusable:

```yaml
models:
  - name: stg_mfg__production_log
    columns:
      - name: record_id
        tests: [unique, not_null]
      - name: department
        tests:
          - accepted_values:
              values: ['sewing', 'finishing']
```

That `accepted_values` test is the one that catches `sweing` and
`'finishing '` if the staging cleanup ever regresses — the exact bug
described in [§9](#9--the-dataset), pinned down so it cannot come back
silently.

**Singular** — a `.sql` file in `tests/` that returns rows *only when
something is wrong*:

```sql
-- tests/assert_item_total_not_above_sales.sql
-- A discount cannot make a line worth MORE than its gross.
select order_item_id, sales, item_total
from {{ ref('stg_dist__order_items') }}
where item_total > sales + 0.01
```

Zero rows = pass.

### Seed

A CSV in `seeds/` that dbt loads as a table with `dbt seed`. Right for small,
hand-maintained reference data that belongs in version control.

`team_product_line.csv` is the honest candidate — 12 rows, authored, changes
by hand. It is loaded via `\copy` in [§7](#7--load-the-csvs) instead, to keep
one loading path for the lab, but **as a seed is arguably where it belongs**,
and saying so is a good answer to "when would you use a seed?".

The 48,998-row `order_items.csv` is **not** a seed candidate. Seeds are for
reference data, not bulk ingest — `dbt seed` builds a giant `INSERT` and is
far slower than `\copy`.

### Snapshot

Captures slowly-changing dimensions over time — dbt records a row's state
and adds `dbt_valid_from` / `dbt_valid_to` when it changes.

**Not usable here, and knowing why matters.** These are static historical
extracts; nothing mutates between runs, so a snapshot would record one
version forever. Snapshots need a mutable source — a production `customers`
table that gets `UPDATE`d in place, where yesterday's value is otherwise
lost.

### Materialisation

How dbt persists a model: `view` (no storage, always fresh), `table` (rebuilt
each run), `ephemeral` (inlined as a CTE, no object), `incremental` (only new
rows). Set per folder in `dbt_project.yml` — see
[§11](#11--build-the-dbt-project).

`incremental` is the one this project could genuinely use if the order feed
were live: with 48,998 rows a full rebuild is instant, but at 50 M it would
not be, and `is_incremental()` plus a `unique_key` is the standard answer.

### Documentation

`dbt docs generate && dbt docs serve` builds a browsable site from the YAML
descriptions plus the DAG. The lineage graph — raw source → staging →
intermediate → mart — is the single most persuasive artefact to show in an
interview, because it makes the layering visible.

---

## 11 — Build the dbt project

### Folder layout

```
models/garment_supply_chain/
├── _sources.yml
├── staging/
│   ├── _schema.yml
│   ├── stg_mfg__production_log.sql
│   ├── stg_mfg__team_product_line.sql
│   ├── stg_dist__categories.sql
│   ├── stg_dist__products.sql
│   ├── stg_dist__customers.sql
│   ├── stg_dist__orders.sql
│   └── stg_dist__order_items.sql
├── intermediate/
│   └── int_order_lines_enriched.sql
└── marts/
    ├── _schema.yml
    ├── fct_order_lines.sql
    ├── dim_customers.sql
    ├── fct_daily_production.sql
    └── fct_supply_chain_weekly.sql
```

The `stg_<source>__<table>` naming is dbt's convention: the double
underscore separates source system from table, so `stg_mfg__production_log`
and `stg_dist__orders` sort into visible groups and never collide.

### `dbt_project.yml`

Add alongside the existing `credit_risk_marts` block:

```yaml
models:
  pipelines_dbt_postgresql:
    +materialized: view
    credit_risk_marts:
      staging:      {+materialized: view,      +schema: staging}
      intermediate: {+materialized: ephemeral, +schema: intermediate}
      marts:        {+materialized: table,     +schema: marts}
    garment_supply_chain:
      staging:      {+materialized: view,      +schema: staging}
      intermediate: {+materialized: ephemeral, +schema: intermediate}
      marts:        {+materialized: table,     +schema: marts}
```

These `+schema` values only land as bare `staging` / `intermediate` /
`marts` because `macros/generate_schema_name.sql` overrides dbt's default
concatenation. Without that macro you get `staging_marts`. It is already in
the repo — do not delete it.

### `_sources.yml`

```yaml
version: 2

sources:
  - name: mfg_raw
    schema: mfg_raw
    description: >
      Garment factory floor. Written only by the \copy load in §7 --
      dbt never writes here, so a bad dbt run cannot destroy ingested data.
    loaded_at_field: loaded_at
    freshness:
      warn_after: {count: 30, period: day}
    tables:
      - name: production_log
        description: >
          UCI 597. Grain: one row per team, per department, per day.
          Carries real source defects -- 'sweing', 'finishing ' with a
          trailing space, Quarter5 -- all handled in staging.
      - name: team_product_line
        description: >
          AUTHORED, not source data. Bridges factory teams to DataCo
          product categories; the two sources share no natural key.
          category_id values are real DataCo ids.

  - name: dist_raw
    schema: dist_raw
    description: DataCo Smart Supply Chain, Apparel department only.
    loaded_at_field: loaded_at
    freshness:
      warn_after: {count: 30, period: day}
    tables:
      - name: categories
      - name: products
      - name: customers
      - name: orders
        description: "Grain: one row per order."
      - name: order_items
        description: "Grain: one row per order line."
```

### Staging models

`staging/stg_mfg__production_log.sql` — where all the source dirt from
[§9](#9--the-dataset) is dealt with:

```sql
-- Cast, rename, decode. No joins, no aggregation -- those belong downstream.
--
-- Three source defects handled here and nowhere else:
--   'sweing'      is a misspelling of "sewing", in the source itself
--   'finishing '  carries a trailing space on 257 of 506 rows, so a raw
--                 GROUP BY department returns THREE groups for TWO real
--                 departments and nothing about the output looks wrong
--   'quarter'     is week-of-month, not a calendar quarter (Quarter5 exists)
--
-- Two things deliberately NOT "fixed":
--   wip is NULL on every finishing row -- WIP is a sewing concept, so the
--     NULL is meaningful and imputing it would invent data
--   actual_productivity exceeds 1.0 (max 1.120) -- teams beat target;
--     clamping would destroy the most interesting rows in the table

with source as (

    select * from {{ source('mfg_raw', 'production_log') }}

),

renamed as (

    select
        record_id,
        work_date,

        case trim(department)
            when 'sweing'    then 'sewing'
            when 'finishing' then 'finishing'
            else trim(department)   -- surfaced by the accepted_values test
        end                                          as department,

        replace(quarter, 'Quarter', '')::smallint     as week_of_month,
        day_name,
        team,

        targeted_productivity,
        actual_productivity,
        round(actual_productivity
              / nullif(targeted_productivity, 0), 4)  as target_attainment,
        (actual_productivity >= targeted_productivity) as met_target,

        smv,
        wip,
        over_time                                     as overtime_minutes,
        incentive                                     as incentive_bdt,
        idle_time                                     as idle_minutes,
        idle_men,
        no_of_style_change                            as style_changes,
        no_of_workers                                 as worker_count,

        source                                        as source_system,
        loaded_at

    from source

)

select * from renamed
```

`staging/stg_dist__orders.sql`:

```sql
with source as (

    select * from {{ source('dist_raw', 'orders') }}

),

renamed as (

    select
        order_id,
        customer_id,
        order_date,
        order_date::date                          as order_day,
        shipping_date,

        order_status,
        delivery_status,
        shipping_mode,
        order_type,

        (late_delivery_risk = 1)                  as is_late_risk,
        days_shipping_real,
        days_shipping_sched,
        days_shipping_real - days_shipping_sched  as shipping_days_variance,
        {{ on_time_flag('days_shipping_real', 'days_shipping_sched') }}
                                                  as is_on_time,

        -- Revenue must exclude these two. Defining it once here means no
        -- downstream model has to remember the exclusion list.
        (order_status not in ('CANCELED', 'SUSPECTED_FRAUD'))
                                                  as is_revenue_eligible,

        market,
        order_region,
        order_country,
        order_state,
        order_city,

        source                                    as source_system,
        loaded_at

    from source

)

select * from renamed
```

`staging/stg_dist__order_items.sql` — rounding the float32 artefacts to
business precision, which is exactly the job the raw layer deferred:

```sql
select
    order_item_id,
    order_id,
    product_card_id,
    quantity,
    round(item_price, 2)         as item_price,
    round(discount, 2)           as discount_amount,
    round(discount_rate, 4)      as discount_rate,
    round(sales, 2)              as gross_sales,   -- BEFORE discount
    round(item_total, 2)         as net_revenue,   -- AFTER discount
    round(profit_ratio, 4)       as profit_ratio,
    round(benefit_per_order, 2)  as profit_amount,
    source                       as source_system,
    loaded_at
from {{ source('dist_raw', 'order_items') }}
```

`staging/stg_dist__categories.sql` — one line of real work, fixing `Baby `:

```sql
select
    category_id,
    trim(category_name)   as category_name,   -- 'Baby ' has a trailing space
    department_id,
    trim(department_name) as department_name,
    source                as source_system,
    loaded_at
from {{ source('dist_raw', 'categories') }}
```

`stg_dist__products.sql`, `stg_dist__customers.sql` and
`stg_mfg__team_product_line.sql` follow the same shape — select, rename,
round, `trim()` the category name in the bridge.

### Intermediate

`intermediate/int_order_lines_enriched.sql` — the four-way join every mart
would otherwise repeat. Ephemeral, so it becomes a CTE and creates no
database object:

```sql
with

items      as (select * from {{ ref('stg_dist__order_items') }}),
orders     as (select * from {{ ref('stg_dist__orders') }}),
products   as (select * from {{ ref('stg_dist__products') }}),
categories as (select * from {{ ref('stg_dist__categories') }})

select
    i.order_item_id,
    i.order_id,
    o.customer_id,

    o.order_date,
    o.order_day,
    o.market,
    o.order_region,
    o.order_country,
    o.order_status,
    o.delivery_status,
    o.shipping_mode,
    o.is_on_time,
    o.is_late_risk,
    o.is_revenue_eligible,
    o.shipping_days_variance,

    p.product_card_id,
    p.product_name,
    c.category_id,
    c.category_name,

    i.quantity,
    i.gross_sales,
    i.net_revenue,
    i.discount_amount,
    i.profit_amount,
    i.profit_ratio

from items i
join orders     o on o.order_id        = i.order_id
join products   p on p.product_card_id = i.product_card_id
join categories c on c.category_id     = p.category_id
```

### Marts

`marts/fct_supply_chain_weekly.sql` — **the cross-schema model.** One row per
category per week, factory performance beside downstream demand:

```sql
-- Grain: one row per (week_start, category_id).
--
-- This is the model that spans both source systems. The join is only
-- possible because mfg_raw.team_product_line maps factory teams to DataCo
-- category ids -- an AUTHORED bridge (§9), not source data. Rows exist only
-- for the 59 days the two datasets overlap (Jan 1 -- Mar 11, 2015).

with factory as (

    select
        date_trunc('week', pl.work_date)::date as week_start,
        tpl.category_id,
        avg(pl.target_attainment)              as avg_target_attainment,
        avg(pl.actual_productivity)            as avg_productivity,
        sum(pl.overtime_minutes)               as overtime_minutes,
        sum(pl.idle_minutes)                   as idle_minutes,
        count(*)                               as production_records
    from {{ ref('stg_mfg__production_log') }} pl
    join {{ ref('stg_mfg__team_product_line') }} tpl
      on tpl.team = pl.team
    group by 1, 2

),

demand as (

    select
        date_trunc('week', l.order_day)::date  as week_start,
        l.category_id,
        count(*)                               as order_lines,
        sum(l.quantity)                        as units_ordered,
        sum(l.net_revenue)                     as net_revenue,
        avg(case when l.is_on_time then 1.0 else 0.0 end) as on_time_rate
    from {{ ref('int_order_lines_enriched') }} l
    where l.is_revenue_eligible
    group by 1, 2

)

select
    f.week_start,
    f.category_id,
    c.category_name,

    round(f.avg_target_attainment, 4) as avg_target_attainment,
    round(f.avg_productivity, 4)      as avg_productivity,
    f.overtime_minutes,
    f.idle_minutes,
    f.production_records,

    d.order_lines,
    d.units_ordered,
    round(d.net_revenue, 2)           as net_revenue,
    round(d.on_time_rate, 4)          as on_time_rate

from factory f
join demand d
  on d.week_start  = f.week_start
 and d.category_id = f.category_id
join {{ ref('stg_dist__categories') }} c
  on c.category_id = f.category_id
```

`fct_order_lines` (grain: one order line), `dim_customers` (one customer,
with lifetime totals) and `fct_daily_production` (one team-day) follow the
same pattern — thin selects over the intermediate or staging layer.

### The macro

`macros/on_time_flag.sql`:

```sql
{% macro on_time_flag(real_days, sched_days) %}
    case
        when {{ real_days }} is null or {{ sched_days }} is null then null
        when {{ real_days }} <= {{ sched_days }} then true
        else false
    end
{% endmacro %}
```

### Tests

`staging/_schema.yml`, including the test that pins down the source defect:

```yaml
version: 2

models:
  - name: stg_mfg__production_log
    description: "Grain: one row per team, per department, per day."
    columns:
      - name: record_id
        tests: [unique, not_null]
      - name: department
        description: "'sweing' and 'finishing ' normalised here."
        tests:
          - not_null
          - accepted_values:
              values: ['sewing', 'finishing']
      - name: team
        tests:
          - not_null
          - relationships:
              to: ref('stg_mfg__team_product_line')
              field: team

  - name: stg_dist__orders
    columns:
      - name: order_id
        tests: [unique, not_null]
      - name: customer_id
        tests:
          - relationships:
              to: ref('stg_dist__customers')
              field: customer_id
      - name: delivery_status
        tests:
          - accepted_values:
              values: ['Advance shipping', 'Late delivery',
                       'Shipping canceled', 'Shipping on time']
```

Plus a singular test, `tests/assert_item_total_not_above_sales.sql`:

```sql
-- item_total is net of discount, sales is gross. A discount cannot make a
-- line worth more than its gross value. Returns rows only on failure.
select order_item_id, gross_sales, net_revenue
from {{ ref('stg_dist__order_items') }}
where net_revenue > gross_sales + 0.01
```

### Run it

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && ./venv/bin/dbt build --select garment_supply_chain
```

`dbt build` runs models and tests together in dependency order, stopping a
branch when its upstream test fails — which is what you want, and what
`dbt run && dbt test` does not give you.

Then check the sources are fresh and publish the docs:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && ./venv/bin/dbt source freshness && ./venv/bin/dbt docs generate && ./venv/bin/dbt docs serve
```

---

## 12 — Export CSV for Power BI / Tableau

### First: prefer a live connection

Both tools speak PostgreSQL natively, and a live connection beats a CSV on
every axis that matters — refresh, types, no stale copies:

- **Tableau** — *Connect → To a Server → PostgreSQL*: host `192.168.1.71`,
  port `5432`, database `garment_lab`, user `app_garment`. Point it at the
  `marts` schema.
- **Power BI** — *Get Data → PostgreSQL database*: server
  `192.168.1.71:5432`, database `garment_lab`. Use **Import** for this size;
  DirectQuery buys nothing on 49 K rows.

> **Power BI Desktop is Windows-only.** On your Mac that means running it on
> the `192.168.1.71` box itself (where the host is `localhost`) or in a VM.
> Tableau Desktop runs natively on macOS. This is the main practical reason
> to want the CSV export below — a handoff to someone on the other platform.

### The export

`\copy (query) TO` is the mirror of the load in [§7](#7--load-the-csvs):
client-side, writes to **the machine running psql**, needs no special grant.

```bash
mkdir -p ~/Documents/bi_exports && cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && PGPASSWORD='<password-from-step-2>' psql -U app_garment -h 192.168.1.71 -d garment_lab -c "\copy (SELECT * FROM marts.fct_supply_chain_weekly ORDER BY week_start, category_name) TO '/Users/gamaliel/Documents/bi_exports/fct_supply_chain_weekly.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')"
```

Change the path in `TO '...'` to put it anywhere you like — a Dropbox
folder, a mounted share, `~/Desktop`. The directory must already exist;
`\copy` will not create it.

`ENCODING 'UTF8'` is not optional here. This server runs
`lc_messages = Spanish_Mexico.1252`, and the customer names carry accented
characters — without it you can get CP1252 output that Power BI reads as
mojibake.

### A reusable helper

Add to `~/.zshrc`, then `export_mart <model> [dir]`:

```bash
export_mart() {
  local model="$1"
  local outdir="${2:-$HOME/Documents/bi_exports}"
  mkdir -p "$outdir"
  PGPASSWORD="$GARMENT_LAB_PW" psql -U app_garment -h 192.168.1.71 -d garment_lab \
    -c "\copy (SELECT * FROM marts.${model}) TO '${outdir}/${model}.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')" \
    && echo "wrote ${outdir}/${model}.csv"
}
```

With `GARMENT_LAB_PW` set in your shell environment rather than typed each
time — and kept out of the repo, same rule as `profiles.yml`.

```bash
export_mart fct_supply_chain_weekly && export_mart fct_order_lines && export_mart dim_customers
```

### Exporting every mart at once

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && for m in $(PGPASSWORD="$GARMENT_LAB_PW" psql -U app_garment -h 192.168.1.71 -d garment_lab -At -c "SELECT table_name FROM information_schema.tables WHERE table_schema='marts' ORDER BY 1"); do export_mart "$m"; done
```

### Excel-friendly variant

Excel on a Spanish-locale Windows machine will not split a comma-separated
file on double-click, and will mangle UTF-8 without a BOM. If the CSV is
destined for that, use semicolons and prepend a BOM:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && PGPASSWORD="$GARMENT_LAB_PW" psql -U app_garment -h 192.168.1.71 -d garment_lab -c "\copy (SELECT * FROM marts.fct_supply_chain_weekly) TO '/tmp/x.csv' WITH (FORMAT csv, HEADER true, DELIMITER ';', ENCODING 'UTF8')" && printf '\xEF\xBB\xBF' | cat - /tmp/x.csv > ~/Documents/bi_exports/fct_supply_chain_weekly_excel.csv && rm /tmp/x.csv
```

Power BI and Tableau both handle plain UTF-8 commas correctly — this is an
Excel-only workaround.

### Why not `COPY ... TO '/path'`

Server-side `COPY` writes to the **server's** filesystem (a Windows path,
under the `NT AUTHORITY\NetworkService` account) and requires superuser or
membership in `pg_write_server_files`. For a lab whose entire point is
getting data onto your Mac, it is the wrong tool. Use it only when you
genuinely want the file to land on `192.168.1.71`.

### Keeping the export current

The export is a snapshot. It is stale the moment a model is rebuilt, so run
it **after** `dbt build`, not before:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && ./venv/bin/dbt build --select garment_supply_chain && export_mart fct_supply_chain_weekly
```

---

## 13 — SQL exercises

Ten queries, each adding one idea to the last. **They run against the raw
schemas**, so you can work through them immediately after
[§7](#7--load-the-csvs) without building the dbt project — which also means
you meet the source dirt from [§9](#9--the-dataset) head-on, exactly as you
would on a real first day.

Run them from the client:

```bash
PGPASSWORD='<password-from-step-2>' psql -U app_garment -h 192.168.1.71 -d garment_lab
```

| # | Adds | Crosses schemas | Window |
|---|---|---|---|
| 1 | inner joins, `GROUP BY` | | |
| 2 | fan-out, `HAVING` | | |
| 3 | the bridge table | ✓ | |
| 4 | `ROW_NUMBER`, partitioned total | | ✓ |
| 5 | `LAG`, named `WINDOW` | | ✓ |
| 6 | frames: running total, moving average | | ✓ |
| 7 | `NTILE`, aggregate-of-aggregate | | ✓ |
| 8 | both sides, weekly grain | ✓ | ✓ |
| 9 | gaps and islands | | ✓ |
| 10 | `LEAD` lookahead, capstone | ✓ | ✓ |

---

### 1 — Revenue by category

Three tables, one schema. `item_total` is the **net** revenue column;
`sales` is gross, before discount.

```sql
SELECT
    c.category_name,
    count(*)                     AS order_lines,
    sum(oi.quantity)             AS units,
    round(sum(oi.item_total), 2) AS net_revenue
FROM dist_raw.order_items oi
JOIN dist_raw.products    p ON p.product_card_id = oi.product_card_id
JOIN dist_raw.categories  c ON c.category_id     = p.category_id
GROUP BY c.category_name
ORDER BY net_revenue DESC;
```

`round(x, 2)` needs a `numeric` — it has no `double precision` overload in
PostgreSQL. That is why the money columns are `NUMERIC` in
[§6](#6--create-the-raw-tables); with `float8` this line fails with
`function round(double precision, integer) does not exist`.

---

### 2 — Late deliveries by market and segment

Adds a fourth table, a `WHERE` on order status, and `HAVING`.

```sql
SELECT
    o.market,
    cu.segment,
    count(DISTINCT o.order_id)                             AS orders,
    count(*)                                               AS order_lines,
    round(sum(oi.item_total), 2)                           AS net_revenue,
    round(100.0 * sum(o.late_delivery_risk) / count(*), 1) AS pct_lines_late
FROM dist_raw.orders      o
JOIN dist_raw.customers   cu ON cu.customer_id = o.customer_id
JOIN dist_raw.order_items oi ON oi.order_id    = o.order_id
WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
GROUP BY o.market, cu.segment
HAVING count(DISTINCT o.order_id) > 200
ORDER BY net_revenue DESC;
```

**The trap, and it is the most common one in this schema.** Joining `orders`
to `order_items` fans each order out into one row per line. `count(*)` is
therefore lines, not orders — hence `count(DISTINCT o.order_id)`. And
`sum(o.late_delivery_risk)` counts a late order *once per line it contains*,
so `pct_lines_late` is a line-weighted rate, not an order-weighted one.

Neither is wrong, but they answer different questions and the SQL does not
tell you which you got. Order-weighted needs the order grain kept separate:

```sql
SELECT
    o.market,
    count(*)                                             AS orders,
    round(100.0 * sum(o.late_delivery_risk) / count(*), 1) AS pct_orders_late
FROM dist_raw.orders o
WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
GROUP BY o.market
ORDER BY pct_orders_late DESC;
```

`HAVING` filters *after* grouping; `WHERE` filters before. Swapping them
here would be a syntax error, since `count()` does not exist yet at `WHERE`
time.

---

### 3 — First cross-schema join

`mfg_raw` → `dist_raw`, through the authored bridge. This is only possible
because both schemas live in one database ([§0](#0--design)).

```sql
SELECT
    tpl.product_line,
    c.category_name,
    count(*)                                AS production_records,
    round(avg(pl.targeted_productivity), 3) AS avg_target,
    round(avg(pl.actual_productivity), 3)   AS avg_actual,
    round(avg(pl.actual_productivity)
          - avg(pl.targeted_productivity), 3) AS avg_gap
FROM mfg_raw.production_log    pl
JOIN mfg_raw.team_product_line tpl ON tpl.team      = pl.team
JOIN dist_raw.categories       c   ON c.category_id = tpl.category_id
GROUP BY tpl.product_line, c.category_name
ORDER BY avg_gap DESC;
```

Nothing about the syntax changes when you cross a schema — a qualified name
is a qualified name. What changes is that you now need `USAGE` on both
schemas, which `app_garment` has because it owns them.

Note `category_name` comes back with `Baby ` still carrying its trailing
space. That is the raw layer being faithful; `stg_dist__categories` trims it.

---

### 4 — Top 3 products per market

First window function. `ROW_NUMBER()` ranks inside each market; the second
window computes a market total *without collapsing the rows*, which is the
thing `GROUP BY` cannot do.

```sql
WITH revenue_by_product AS (
    SELECT
        o.market,
        p.product_name,
        sum(oi.item_total) AS net_revenue
    FROM dist_raw.orders      o
    JOIN dist_raw.order_items oi ON oi.order_id       = o.order_id
    JOIN dist_raw.products    p  ON p.product_card_id = oi.product_card_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY o.market, p.product_name
),
ranked AS (
    SELECT
        market,
        product_name,
        net_revenue,
        row_number() OVER (PARTITION BY market ORDER BY net_revenue DESC) AS rn,
        round(100.0 * net_revenue
              / sum(net_revenue) OVER (PARTITION BY market), 1) AS pct_of_market
    FROM revenue_by_product
)
SELECT market, rn, product_name, round(net_revenue, 2) AS net_revenue, pct_of_market
FROM ranked
WHERE rn <= 3
ORDER BY market, rn;
```

**Two rules worth memorising:**

- A window function cannot appear in `WHERE` — windows are evaluated *after*
  `WHERE`. That is why `rn <= 3` needs the extra CTE. `QUALIFY` would do it
  in one step, but PostgreSQL has no `QUALIFY`.
- Windows run *after* `GROUP BY`, which is why `sum(net_revenue) OVER (...)`
  in the outer CTE sums the already-grouped rows.

Picking the right ranker:

| | ties | gaps after a tie |
|---|---|---|
| `ROW_NUMBER()` | broken arbitrarily | — |
| `RANK()` | share a rank | yes: 1, 1, 3 |
| `DENSE_RANK()` | share a rank | no: 1, 1, 2 |

`ROW_NUMBER()` for "exactly 3 rows per market". `RANK()` if a genuine tie
should return four.

---

### 5 — Day-over-day productivity per team

`LAG()` reaches back within a partition. The named `WINDOW` clause defines
the frame once instead of repeating it on every call.

```sql
SELECT
    pl.work_date,
    pl.team,
    round(pl.actual_productivity, 3)                        AS productivity,
    round(lag(pl.actual_productivity) OVER w, 3)            AS prev_workday,
    round(pl.actual_productivity
          - lag(pl.actual_productivity) OVER w, 3)          AS delta,
    pl.work_date - lag(pl.work_date) OVER w                 AS days_since_prev
FROM mfg_raw.production_log pl
WHERE trim(pl.department) = 'sweing'
WINDOW w AS (PARTITION BY pl.team ORDER BY pl.work_date)
ORDER BY pl.team, pl.work_date
LIMIT 40;
```

Three things to notice:

- **`trim(pl.department) = 'sweing'`** — the misspelling *and* the trailing
  space, both live. Drop the `trim()` and you silently lose rows. This is
  the case for a staging layer, in one line of SQL.
- **`days_since_prev` is often 2, not 1.** There is no Friday in this data —
  it is the weekend in Bangladesh. "Previous row" is not "yesterday", and
  any query that assumes otherwise is wrong.
- `LAG` returns `NULL` on the first row of each partition. `lag(x, 1, 0)`
  supplies a default if you would rather have one.

`(work_date, team, trim(department))` is unique — 1,197 rows, 1,197
combinations, enforced by the index in [§6](#6--create-the-raw-tables). If it
were not, the `ORDER BY` inside the window would be non-deterministic and
`delta` would change between runs.

---

### 6 — Running total and 7-day moving average

Frames. `ROWS BETWEEN ... ` is what turns a window from "the whole partition"
into "a sliding stretch of it".

```sql
WITH daily AS (
    SELECT
        o.order_date::date AS order_day,
        sum(oi.item_total) AS net_revenue
    FROM dist_raw.orders      o
    JOIN dist_raw.order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
      AND o.order_date >= DATE '2015-01-01'
      AND o.order_date <  DATE '2015-04-01'
    GROUP BY 1
)
SELECT
    order_day,
    round(net_revenue, 2) AS net_revenue,
    round(sum(net_revenue) OVER (ORDER BY order_day
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS running_total,
    round(avg(net_revenue) OVER (ORDER BY order_day
              ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)         AS ma_7d,
    round(net_revenue - avg(net_revenue) OVER (ORDER BY order_day
              ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)         AS vs_ma
FROM daily
ORDER BY order_day;
```

**`ROWS` vs `RANGE`, and why it matters here.** `ROWS BETWEEN 6 PRECEDING`
counts *rows*; `RANGE BETWEEN 6 PRECEDING` counts *values of the ORDER BY
expression*. They agree only when every day is present. Here they mostly
are — but `ROWS` on a series with a missing day gives you a 7-row average
spanning 8 calendar days, silently.

If you need true calendar semantics, say so:

```sql
avg(net_revenue) OVER (ORDER BY order_day
    RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW)
```

And note the default: an `OVER` with an `ORDER BY` and **no** frame clause is
`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — which makes ties share
one cumulative value. Omitting `ORDER BY` too gives the whole partition. The
running total above is explicit precisely so it does not depend on
remembering that.

---

### 7 — Customer value quartiles

`NTILE(4)` buckets customers by lifetime revenue. The interesting line is
`sum(sum(...)) OVER ()` — an aggregate wrapped in a window, which is how you
get "this group's share of the whole" in one pass.

```sql
WITH customer_value AS (
    SELECT
        o.customer_id,
        count(DISTINCT o.order_id) AS orders,
        sum(oi.item_total)         AS lifetime_revenue,
        max(o.order_date)::date    AS last_order_day
    FROM dist_raw.orders      o
    JOIN dist_raw.order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY o.customer_id
),
banded AS (
    SELECT
        cv.*,
        ntile(4)      OVER (ORDER BY lifetime_revenue DESC) AS value_quartile,
        percent_rank() OVER (ORDER BY lifetime_revenue)     AS pct_rank
    FROM customer_value cv
)
SELECT
    value_quartile,
    count(*)                        AS customers,
    round(min(lifetime_revenue), 2) AS min_revenue,
    round(max(lifetime_revenue), 2) AS max_revenue,
    round(sum(lifetime_revenue), 2) AS total_revenue,
    round(100.0 * sum(lifetime_revenue)
          / sum(sum(lifetime_revenue)) OVER (), 1) AS pct_of_all_revenue,
    round(avg(orders), 2)           AS avg_orders
FROM banded
GROUP BY value_quartile
ORDER BY value_quartile;
```

The nesting reads inside-out: `sum(lifetime_revenue)` collapses each
quartile, then `sum(...) OVER ()` adds those four subtotals into a grand
total repeated on every row. Legal because windows run after `GROUP BY` —
the same rule as exercise 4, used for a different purpose.

`NTILE` splits by **row count**, not by value. Quartile 1 is the top 25% of
*customers*, not the customers making up 25% of revenue. For the latter you
want a cumulative share and a `WHERE` on it.

---

### 8 — Factory output vs downstream delivery, weekly

Both schemas, aggregated to a common grain, then windowed. This is the shape
of the `fct_supply_chain_weekly` model in [§11](#11--build-the-dbt-project).

```sql
WITH factory AS (
    SELECT
        date_trunc('week', pl.work_date)::date AS week_start,
        tpl.category_id,
        avg(pl.actual_productivity
            / nullif(pl.targeted_productivity, 0)) AS target_attainment,
        sum(pl.over_time)                          AS overtime_minutes
    FROM mfg_raw.production_log    pl
    JOIN mfg_raw.team_product_line tpl ON tpl.team = pl.team
    GROUP BY 1, 2
),
demand AS (
    SELECT
        date_trunc('week', o.order_date)::date AS week_start,
        p.category_id,
        count(*)                               AS order_lines,
        sum(oi.item_total)                     AS net_revenue,
        avg(o.late_delivery_risk::numeric)     AS late_rate
    FROM dist_raw.orders      o
    JOIN dist_raw.order_items oi ON oi.order_id       = o.order_id
    JOIN dist_raw.products    p  ON p.product_card_id = oi.product_card_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
      AND o.order_date >= DATE '2015-01-01'
      AND o.order_date <  DATE '2015-03-12'
    GROUP BY 1, 2
)
SELECT
    f.week_start,
    c.category_name,
    round(f.target_attainment, 3) AS attainment,
    f.overtime_minutes,
    d.order_lines,
    round(d.net_revenue, 2)       AS net_revenue,
    round(d.late_rate, 3)         AS late_rate,
    round(avg(d.late_rate) OVER (PARTITION BY c.category_name
              ORDER BY f.week_start
              ROWS BETWEEN 3 PRECEDING AND CURRENT ROW), 3) AS late_rate_4wk,
    round(f.target_attainment - lag(f.target_attainment)
              OVER (PARTITION BY c.category_name ORDER BY f.week_start), 3)
                                  AS attainment_wow
FROM factory f
JOIN demand   d ON d.week_start  = f.week_start
               AND d.category_id = f.category_id
JOIN dist_raw.categories c ON c.category_id = f.category_id
ORDER BY c.category_name, f.week_start;
```

`nullif(targeted_productivity, 0)` guards the division. `targeted_productivity`
has no zeros today, but a divide-by-zero is a hard error in PostgreSQL, not a
`NULL` — and one bad row would take the whole query down.

`late_delivery_risk::numeric` before `avg()` matters: it is `SMALLINT`, and
`avg()` on an integer type returns `numeric` anyway here, but the explicit
cast documents that you want a *rate*, not a count.

`date_trunc('week', ...)` gives ISO weeks starting Monday. That is a
convention, not a law — if the business reports Sunday-start weeks, this is
silently off by a day.

**The join is an inner join, so weeks with production but no orders (or the
reverse) disappear.** With only 59 overlapping days, that is a real effect —
`FULL OUTER JOIN` plus `coalesce` on the key columns is the honest version
if absence is meaningful.

---

### 9 — Streaks of missed targets

Gaps and islands. The trick is that two `ROW_NUMBER()`s — one over the whole
partition, one over the partition split by the flag — drift apart by a
constant *only while the flag stays the same*. That constant identifies the
run.

```sql
WITH days AS (
    SELECT
        pl.team,
        pl.work_date,
        (pl.actual_productivity < pl.targeted_productivity) AS missed_target
    FROM mfg_raw.production_log pl
    WHERE trim(pl.department) = 'sweing'
),
grouped AS (
    SELECT
        team,
        work_date,
        missed_target,
        row_number() OVER (PARTITION BY team ORDER BY work_date)
      - row_number() OVER (PARTITION BY team, missed_target ORDER BY work_date)
            AS island
    FROM days
),
streaks AS (
    SELECT
        team,
        missed_target,
        island,
        min(work_date) AS streak_start,
        max(work_date) AS streak_end,
        count(*)       AS streak_days
    FROM grouped
    GROUP BY team, missed_target, island
)
SELECT team, streak_start, streak_end, streak_days
FROM streaks
WHERE missed_target
ORDER BY streak_days DESC, team
LIMIT 15;
```

Run the `grouped` CTE on its own for one team and watch the two row numbers
to see why it works — it is much clearer than any description of it.

`streak_days` counts **production days, not calendar days**. With no Fridays
in the data, a 4-day streak can span 5 dates. `streak_end - streak_start + 1`
tells you which, and the difference is worth stating in any report built on
this.

---

### 10 — Capstone: the worst week, and what happened next

Everything at once — both schemas, `LAG` behind, `LEAD` ahead, a running
frame, and a rank used to pick one row per group.

**Question:** for each category, find the week factory attainment fell
hardest, and show what downstream on-time delivery did in the two weeks that
followed.

```sql
WITH weekly_factory AS (
    SELECT
        date_trunc('week', pl.work_date)::date AS week_start,
        tpl.category_id,
        avg(pl.actual_productivity
            / nullif(pl.targeted_productivity, 0)) AS attainment
    FROM mfg_raw.production_log    pl
    JOIN mfg_raw.team_product_line tpl ON tpl.team = pl.team
    GROUP BY 1, 2
),
weekly_demand AS (
    SELECT
        date_trunc('week', o.order_date)::date AS week_start,
        p.category_id,
        sum(oi.item_total) AS net_revenue,
        avg(CASE WHEN o.days_shipping_real <= o.days_shipping_sched
                 THEN 1.0 ELSE 0.0 END) AS on_time_rate
    FROM dist_raw.orders      o
    JOIN dist_raw.order_items oi ON oi.order_id       = o.order_id
    JOIN dist_raw.products    p  ON p.product_card_id = oi.product_card_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY 1, 2
),
joined AS (
    SELECT
        f.week_start,
        f.category_id,
        f.attainment,
        d.net_revenue,
        d.on_time_rate,
        f.attainment - lag(f.attainment)
            OVER (PARTITION BY f.category_id ORDER BY f.week_start)
                                                        AS attainment_wow,
        lead(d.on_time_rate, 1)
            OVER (PARTITION BY f.category_id ORDER BY f.week_start)
                                                        AS on_time_wk_plus_1,
        lead(d.on_time_rate, 2)
            OVER (PARTITION BY f.category_id ORDER BY f.week_start)
                                                        AS on_time_wk_plus_2,
        avg(d.net_revenue) OVER (PARTITION BY f.category_id
            ORDER BY f.week_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                        AS cum_avg_revenue
    FROM weekly_factory f
    JOIN weekly_demand  d ON d.week_start  = f.week_start
                         AND d.category_id = f.category_id
),
ranked AS (
    SELECT
        j.*,
        row_number() OVER (PARTITION BY category_id
                           ORDER BY attainment_wow ASC NULLS LAST) AS drop_rank
    FROM joined j
    WHERE attainment_wow IS NOT NULL
)
SELECT
    c.category_name,
    r.week_start                   AS worst_week,
    round(r.attainment, 3)         AS attainment,
    round(r.attainment_wow, 3)     AS wow_change,
    round(r.on_time_rate, 3)       AS on_time_that_week,
    round(r.on_time_wk_plus_1, 3)  AS on_time_wk_plus_1,
    round(r.on_time_wk_plus_2, 3)  AS on_time_wk_plus_2,
    round(r.net_revenue, 2)        AS net_revenue,
    round(r.cum_avg_revenue, 2)    AS cum_avg_revenue
FROM ranked r
JOIN dist_raw.categories c ON c.category_id = r.category_id
WHERE r.drop_rank = 1
ORDER BY r.wow_change;
```

Points to be able to defend:

- **`NULLS LAST`.** PostgreSQL sorts `NULL` **first** under `ASC` — the
  opposite of most engines. The `WHERE` already removes them, so it is
  belt-and-braces; leave it in, because the day someone deletes that `WHERE`
  the query silently starts picking a `NULL` row as the worst week.
- **`LEAD` stops at the partition boundary.** `on_time_wk_plus_2` is `NULL`
  for the last two weeks of every category — correct, and a dashboard must
  render it as "no data", never as zero. Subtler: `joined` is an inner join,
  so "next week" means the next week **present in both sources**, not the
  next calendar week. A gap in either one silently changes what `+1` and
  `+2` refer to.
- **This is a correlation across an authored join.** The bridge is synthetic
  ([§9](#9--the-dataset)), so "factory attainment dropped and deliveries
  slipped two weeks later" is a demonstration of the *technique*, not a
  finding about a real supply chain. Say that before anyone asks.

---

### Window function reference

```
function(args) OVER (
    PARTITION BY ...     -- restart per group        (optional)
    ORDER BY ...         -- order within the group   (optional)
    ROWS|RANGE BETWEEN ... AND ...   -- the frame    (optional)
)
```

| Function | Returns |
|---|---|
| `ROW_NUMBER()` | 1, 2, 3 … ties broken arbitrarily |
| `RANK()` / `DENSE_RANK()` | ties share a rank; with / without gaps |
| `NTILE(n)` | bucket number, split by row count |
| `PERCENT_RANK()` / `CUME_DIST()` | relative standing, 0–1 |
| `LAG(x, n, default)` / `LEAD(...)` | value n rows back / ahead |
| `FIRST_VALUE(x)` / `LAST_VALUE(x)` | edges of the **frame**, not the partition |
| `NTH_VALUE(x, n)` | nth row of the frame |
| `sum` `avg` `count` `min` `max` … `OVER` | any aggregate, without collapsing rows |

Four things that cause most of the bugs:

1. **No window functions in `WHERE` or `GROUP BY`.** Wrap in a CTE and filter
   outside — exercises 4 and 10.
2. **`LAST_VALUE` needs an explicit frame.** With the default
   (`UNBOUNDED PRECEDING` to `CURRENT ROW`) it returns the current row. Use
   `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`.
3. **`ORDER BY` inside the window is separate** from the query's final
   `ORDER BY`. Getting the right numbers in the wrong display order is
   normal; the fix is the outer one.
4. **`ROWS` counts rows, `RANGE` counts values.** They differ exactly when
   the series has gaps or ties — exercise 6.

---

## 14 — Teardown

The reason for building it this way. Run on the server as superuser:

```powershell
$pgbin = "C:\Program Files\PostgreSQL\18\bin"
$env:PGPASSWORD = "<postgres password>"

& "$pgbin\psql.exe" -U postgres -h 127.0.0.1 -d postgres `
  -c "DROP DATABASE IF EXISTS garment_lab;" `
  -c "DROP ROLE IF EXISTS app_garment;"

Remove-Item Env:\PGPASSWORD
```

No tablespace to drop, no folder to delete, no `icacls` grant to clean up —
that is the whole payoff of [§0](#what-disposable-changes). Compare with
`analytics_lab`, which additionally needs `DROP TABLESPACE` and a
filesystem cleanup.

If `DROP DATABASE` fails with **`database "garment_lab" is being accessed by
other users`**, something still holds a connection — a `dbt docs serve`, an
open psql, a Tableau extract refresh. Close it, or force it:

```powershell
& "$pgbin\psql.exe" -U postgres -h 127.0.0.1 -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'garment_lab' AND pid <> pg_backend_pid();"
```

`DROP ROLE` fails while the role still owns objects in *any* database. Drop
the database first — the order above is deliberate.

On the client, undo the two local changes:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/pipelines_dbt_postgresql && sed -i '' "s/^profile: .*/profile: 'analytics_lab'/" dbt_project.yml
```

and delete the `garment_lab:` block from `~/.dbt/profiles.yml`.

---

## 15 — Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| `syntax error at or near ":"` / `error de sintaxis en o cerca de «:»` | `:'var'` interpolation passed via `-c` on this server | use `-f` with a file — [§2](#2--create-the-role) |
| `permission denied for database garment_lab` | dbt cannot create its schemas | `GRANT CREATE ON DATABASE` — [§4](#4--create-the-schemas-and-grants) |
| `must be owner of` / `debe ser dueño de` | tables created as `postgres`, not `app_garment` | `ALTER TABLE ... OWNER TO app_garment` |
| `date/time field value out of range: "2/24/2016"` | `DateStyle` is `DMY` | `SET datestyle = 'ISO, MDY'` in the same session — [§7](#7--load-the-csvs) |
| dates load but `min(work_date)` is wrong | same cause, ambiguous dates parsed silently | truncate, fix DateStyle, reload |
| `extra data after last expected column` | no explicit column list on `\copy` | name the columns — [§7](#7--load-the-csvs) |
| `numeric field overflow` | `NUMERIC(p,s)` too tight for the float32 artefacts | use unconstrained `NUMERIC` in raw |
| `insert or update on table violates foreign key` | CSVs loaded out of order | categories → products → customers → orders → order_items |
| `function round(double precision, integer) does not exist` | column is `float8`, not `numeric` | cast: `round(x::numeric, 2)` |
| `Could not find profile named 'garment_lab'` | no such block in `~/.dbt/profiles.yml` | [§5](#5--add-the-dbt-profile) |
| dbt builds into `staging_marts` | `generate_schema_name.sql` missing | restore the macro — [§10](#macro) |
| `dbt-fusion` in `dbt --version` | a `PATH` dbt shadowing the venv | call `./venv/bin/dbt` explicitly |
| `timeout expired` | wrong address, or firewall | check `192.168.1.71:5432` |
| `Host is down` | server off or asleep | — |
| `'utf-8' codec can't decode byte 0xab` | Spanish `lc_messages` hiding the real error | decode as latin-1, or `SET lc_messages = 'C'` |
| `database ... is being accessed by other users` | open connection during teardown | `pg_terminate_backend` — [§14](#14--teardown) |
| CSV opens as mojibake in Excel | no BOM / comma delimiter on a Spanish Windows | semicolon + BOM variant — [§12](#excel-friendly-variant) |
