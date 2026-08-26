# Credit Risk Marts — Project 1

Models over the two UCI credit datasets, built against the **`credit_risk`**
database on the Windows server.

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
      server_side/sql/03_credit_tablespace_and_db.sql
      server_side/sql/04_credit_role_and_schema.sql  │
      server_side/utils/download_credit_data.py      │
      server_side/utils/load_credit_data.py          │
                    push ──────────────────────────► │
                                                     │
                                    ② git pull  ─────┤
                                    ③ psql -f 03_…   │  tablespace + database
                                    ④ psql -f 04_…   │  role + schemas + tables
                                    ⑤ download_…py   │  UCI → datasets/*.csv
                                    ⑥ load_…py       │  CSV → credit_raw.*
                                                     │
                                    push (datasets) ─┤
   ⑦ git pull ◄──────────────────────────────────────┘
   ⑧ write models/credit_risk_marts/
   ⑨ dbt run --profile credit_risk  ─── LAN 5432 ───► analytics.fct_credit_risk
   ⑩ git push
```

Steps ③–⑥ run **on the server**. Everything else runs on the MacBook. The repo
is the same on both machines; only `~/.dbt/profiles.yml` and `server_side/.env`
differ, and neither is committed.

---

## 2 · Server hierarchy — where the objects live

```
Windows cluster 192.168.1.69 · PostgreSQL 18.6
│
├─▷ findata                      tablespace: financial_tablespace
│    ├─▷ crypto_fx               assets, price_history      ← Project 4
│    ├─▷ analytics               dbt marts for crypto
│    └─▷ public
│
├─▷ credit_risk                  tablespace: credit_tablespace     ← NEW
│    ├─▷ credit_raw              credit_default, german_credit
│    │      └─ loaded by server_side/utils/load_credit_data.py
│    ├─▷ analytics               dbt writes marts here
│    └─▷ public
│
├─▷ local                        earlier dbt experiments
└─▷ postgres                     maintenance database
```

### The consequence of two databases

`credit_risk` and `findata` are **separate databases**, so a single query can
never join across them. Postgres allows cross-*schema* joins freely and
cross-*database* joins not at all.

That means every dbt command for this folder must name the profile explicitly:

```bash
dbt run  --profile credit_risk --select credit_risk_marts
dbt test --profile credit_risk --select credit_risk_marts
```

A bare `dbt run` uses the project's default profile (`findata`) and will fail
here, because `credit_raw` does not exist in that database. Always pair
`--select credit_risk_marts` with `--profile credit_risk`.

If you later want credit and FX data in one mart, the two domains have to share
a database — that would mean moving `credit_raw` into `findata` as a schema.

---

## 3 · Layers

| Layer | Schema | Materialization | Job |
|---|---|---|---|
| source | `credit_raw` | tables | landed by the Python loader; dbt never writes here |
| staging | `analytics` | view | cast, rename, decode `A11`-style codes |
| intermediate | `analytics` | ephemeral | reusable logic shared by more than one mart |
| marts | `analytics` | table | what a person or BI tool queries |

The loader owns `credit_raw` and dbt owns `analytics`. Keeping them apart means
a bad `dbt run` can never destroy the ingested source data.

---

## 4 · The two datasets, and why they are here

| Dataset | Rows | Format trap |
|---|---|---|
| Default of Credit Card Clients (Taiwan, 2005) | 30,000 | `.xls` with **two header rows** — real names on row 2 |
| Statlog German Credit | 1,000 | **No header**, space-delimited, coded values (`A11`, `A34`) |

Both are CC BY 4.0. Neither loads with a naive `read_csv`, which is the point:
the cleaning belongs in the loader, and decoding the German codebook into
readable categories belongs in a staging model. That contrast is the staging
layer lesson this project exists to teach.

---

## 5 · Connection settings

`server_side/.env` on the **server** — never committed:

```
PGHOST=localhost
PGPORT=5432
PGDATABASE=credit_risk
PGUSER=app_credit
PGPASSWORD=...
```

`~/.dbt/profiles.yml` on the **client** — never committed:

```yaml
credit_risk:
  target: dev
  outputs:
    dev:
      type: postgres
      host: 192.168.1.69
      port: 5432
      user: app_credit
      pass: '...'
      dbname: credit_risk
      schema: analytics
      threads: 4
      connect_timeout: 5
```
