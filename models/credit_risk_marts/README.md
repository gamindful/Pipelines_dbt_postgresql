# Credit Risk Marts — Project 1

Models over the two UCI credit datasets, built inside the **`credit_risk`
schema** of the `analytics_lab` database.

---

## 1 · Workflow — who does what, in what order

```
                          ┌──────────────────────────────┐
                          │   GitHub · Pipelines_dbt_…   │
                          │   code only, no credentials  │
                          └───────┬──────────────┬───────┘
                             pull │              │ pull
                        ┌─────────▼───┐      ┌───▼──────────┐
                        │  MacBook    │      │  Windows PC  │
                        │  (client)   │      │  (server)    │
                        └─────────────┘      └──────────────┘
                              │                     │
   ① author scripts ──────────┘                     │
      server_side/sql/01_tablespace_and_db.sql      │
      server_side/sql/02_role.sql                   │
      server_side/sql/03_credit_risk_schema.sql     │
      server_side/utils/download_credit_data.py     │
      server_side/utils/load_credit_data.py         │
                    push ──────────────────────────► │
                                                     │
                                    ② git pull  ─────┤
                                    ③ psql -f 01_…   │  tablespace + database
                                    ④ psql -f 02_…   │  role gama
                                    ⑤ psql -f 03_…   │  credit_risk schema + tables
                                    ⑥ download_…py   │  UCI → datasets/*.csv
                                    ⑦ load_…py       │  CSV → credit_risk.*
                                                     │
   ⑧ git pull ◄──────────────────────────────────────┘
   ⑨ write models/credit_risk_marts/
   ⑩ dbt build                    ─── LAN 5432 ───► marts.fct_credit_risk
   ⑪ git push
```

Steps ③–⑦ run **on the server**. Everything else runs on the MacBook. The repo
is identical on both machines; only `~/.dbt/profiles.yml` and
`server_side/.env` differ, and neither is committed.

---

## 2 · Server hierarchy — where the objects live

```
Windows cluster 192.168.1.69 · PostgreSQL 18.6
│
└─▷ analytics_lab                tablespace: analytics_tablespace
     ├─▷ credit_risk             SOURCE — credit_default, german_credit
     │      └─ written only by server_side/utils/load_credit_data.py
     ├─▷ bank_marketing          Project 2 source        (later)
     ├─▷ bankruptcy              Project 3 source        (later)
     ├─▷ market_data             Project 4 source        (later)
     ├─▷ staging                 dbt-owned, created on first run
     ├─▷ intermediate            dbt-owned
     ├─▷ marts                   dbt-owned
     └─▷ public
```

### Why one database

PostgreSQL does not implement cross-database references:

```
ERROR:  cross-database references are not implemented
```

A dbt project connects to exactly one database. Splitting domains across
databases would mean a separate profile per domain, `--profile` on every
command, and marts that could never join across domains. Crossing *schemas* is
free; crossing *databases* is impossible.

So every project in the portfolio lives in `analytics_lab`, one schema per
domain — and **no dbt command here needs `--profile` or `--target`**:

```bash
dbt build --select credit_risk_marts
dbt test  --select credit_risk_marts
```

---

## 3 · Layers

| Layer | Schema | Materialization | Job |
|---|---|---|---|
| source | `credit_risk` | tables | landed by the Python loader; dbt never writes here |
| staging | `staging` | view | cast, rename, decode `A11`-style codes |
| intermediate | `intermediate` | ephemeral | reusable logic shared by more than one mart |
| marts | `marts` | table | what a person or BI tool queries |

The loader owns `credit_risk`; dbt owns the other three. Keeping them apart
means a bad `dbt run` can never destroy the ingested source data.

Set the destinations in `dbt_project.yml` rather than per model:

```yaml
models:
  pipelines_dbt_postgresql:
    credit_risk_marts:
      staging:      {+materialized: view,      +schema: staging}
      intermediate: {+materialized: ephemeral, +schema: intermediate}
      marts:        {+materialized: table,     +schema: marts}
```

---

## 4 · The two datasets, and why they are here

| Dataset | Rows | Format trap |
|---|---|---|
| Default of Credit Card Clients (Taiwan, 2005) | 30,000 | `.xls` with **two header rows** — real names on row 2 |
| Statlog German Credit | 1,000 | **No header**, space-delimited, coded values (`A11`, `A34`) |

Both are CC BY 4.0. Neither loads with a naive `read_csv`, which is the point:
cleaning belongs in the loader, and decoding the German codebook into readable
categories belongs in a staging model.

### Known data-quality issues to resolve in staging

Profiled from the source before it was dropped — the raw tables keep these
faithfully, and the staging layer fixes them:

- `education` is documented as 1–4 but also contains **0, 5, 6** (345 rows)
- `marriage` is documented as 1–3 but also contains **0** (54 rows)
- Their default rates are wildly inconsistent (0.00%, 5.69%, 6.43%) against
  19–25% for documented codes — collapse them to a single `other` category
- Target is imbalanced: **22.1%** default
- Negative `bill_amt*` values are legitimate (overpaid balances) — do not "fix"

A `not_null` test would have caught none of this. An `accepted_values` test on
the decoded staging column catches all of it.

---

## 5 · Connection settings

`server_side/.env` on the **server** — gitignored:

```
PGHOST=localhost
PGPORT=5432
PGDATABASE=analytics_lab
PGUSER=gama
PGPASSWORD=...
```

`~/.dbt/profiles.yml` on the **client** — never committed:

```yaml
analytics_lab:
  target: dev
  outputs:
    dev:
      type: postgres
      host: 192.168.1.69
      port: 5432
      user: gama
      pass: '...'
      dbname: analytics_lab
      schema: staging
      threads: 4
      connect_timeout: 5
```

`schema:` is dbt's **default target for models**, not where sources live.
Sources are named explicitly in `_sources.yml`.
