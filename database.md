# Building the database

How to stand up `analytics_lab` from nothing, up to the point where dbt can
connect and the first schema exists.

> **dbt cannot create a database, a role, or a tablespace.** It creates schemas
> and the objects inside them, against a connection that must already exist.
> That is why steps 1–7 are `psql` and dbt only takes over at step 8.

---

## Design

One database for all five portfolio projects, with domain schemas:

```
analytics_lab                    ← one database, all projects
├─ credit_risk      Project 1 raw tables      created by psql
├─ bank_marketing   Project 2 raw   (later)   created by psql
├─ bankruptcy       Project 3 raw   (later)   created by psql
├─ market_data      Project 4 raw   (later)   created by psql
├─ staging          dbt-owned                 created by dbt
├─ intermediate     dbt-owned                 created by dbt
└─ marts            dbt-owned                 created by dbt
```

**Raw schemas are created by hand and written only by loaders. dbt owns
`staging`, `intermediate` and `marts`.** That separation means a bad `dbt run`
can never destroy ingested source data.

### Why one database and not several

PostgreSQL does not implement cross-database references:

```
ERROR:  cross-database references are not implemented:
        "credit_risk.credit_raw.credit_default"
```

A dbt project connects to exactly one database, so splitting domains across
databases means a separate profile per domain, `--profile` on every command,
and marts that can never join across domains. Crossing *schemas* is free;
crossing *databases* is impossible. Hence: one database, many schemas.

---

## Server steps (Windows, `192.168.1.69`)

### Step 1 — Create the tablespace folder

```powershell
mkdir .\pgdata\analytics_tablespace
```

### Step 2 — Grant the service account access to it

Postgres runs as `NT AUTHORITY\NetworkService`, not as the logged-in user.
Skipping this makes `CREATE TABLESPACE` fail with a permissions error.

```powershell
icacls ".\pgdata\analytics_tablespace" /grant "NT AUTHORITY\NetworkService:(OI)(CI)F"
```

> This grant is lost if the folder is ever deleted and recreated. Reapply it
> after any teardown.

### Step 3 — Create the tablespace and database

Connect to `postgres` — `analytics_lab` does not exist yet. Neither statement
can run inside a transaction block.

```powershell
psql -U postgres -d postgres `
  -c "CREATE TABLESPACE analytics_tablespace LOCATION 'C:/Users/Gamaliel/Documents/GitHub/Financial_analytics/pgdata/analytics_tablespace';" `
  -c "CREATE DATABASE analytics_lab WITH TABLESPACE = analytics_tablespace ENCODING = 'UTF8';"
```

### Step 4 — Generate a password for the application role

```powershell
$pw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | % {[char]$_}); $pw
```

Copy the output — it is needed in steps 5 and 8.

### Step 5 — Create the application role

Passed as a psql variable so it never appears inside a `.sql` file.

```powershell
psql -U postgres -d analytics_lab -v app_password="$pw" `
  -c "CREATE ROLE app_analytics WITH LOGIN PASSWORD :'app_password';" `
  -c "GRANT CONNECT ON DATABASE analytics_lab TO app_analytics;"
```

### Step 6 — Create the first schema: `credit_risk`

```powershell
psql -U postgres -d analytics_lab `
  -c "CREATE SCHEMA credit_risk AUTHORIZATION app_analytics;" `
  -c "GRANT USAGE, CREATE ON SCHEMA credit_risk TO app_analytics;"
```

### Step 7 — Let dbt create its own schemas

```powershell
psql -U postgres -d analytics_lab `
  -c "GRANT CREATE ON DATABASE analytics_lab TO app_analytics;" `
  -c "ALTER ROLE app_analytics SET search_path = credit_risk, staging, marts, public;"
```

Verify — `credit_risk` owned by `app_analytics`, and nothing else yet:

```powershell
psql -U postgres -d analytics_lab -c "\dn" -c "\du app_analytics"
```

---

## Client steps (macOS)

### Step 8 — Add the profile

Substitute the password from step 4. This file lives outside the repository and
is never committed.

```bash
cat >> ~/.dbt/profiles.yml <<'EOF'

analytics_lab:
  target: dev
  outputs:
    dev:
      type: postgres
      host: 192.168.1.69
      port: 5432
      user: app_analytics
      pass: '<password-from-step-4>'
      dbname: analytics_lab
      schema: staging
      threads: 4
      connect_timeout: 5
EOF
```

`schema:` is dbt's **default target for models** — not where sources live.
Sources are named explicitly in YAML.

### Step 9 — Point the project at it

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/Pipelines_dbt_postgresql && sed -i '' "s/^profile: .*/profile: 'analytics_lab'/" dbt_project.yml
```

With exactly one database, this is the **last time** this line changes. No
`--profile`, no `--target`, no flipping between projects.

### Step 10 — Verify the connection

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/Pipelines_dbt_postgresql && ./venv/bin/dbt debug
```

`All checks passed!` means the database is ready and dbt can reach it.

---

## Where this stops

`analytics_lab` exists with an empty `credit_risk` schema and a working dbt
connection. Nothing is in the schema yet.

**Next:** source tables and the loader, then the first staging model.

Two things to carry into that stage:

- Every raw table needs a `loaded_at TIMESTAMPTZ NOT NULL DEFAULT now()`
  column. Without it `dbt source freshness` cannot be configured at all, and
  Project 4 depends on it.
- Add `+schema:` configs per model folder in `dbt_project.yml`, so staging
  models land in `staging` and marts in `marts` rather than everything
  defaulting to the profile's schema.

---

## Reference

| Object | Name | Created by |
|---|---|---|
| Tablespace | `analytics_tablespace` | psql, step 3 |
| Database | `analytics_lab` | psql, step 3 |
| Role | `app_analytics` | psql, step 5 |
| First schema | `credit_risk` | psql, step 6 |
| Model schemas | `staging`, `intermediate`, `marts` | dbt, on first run |
| Profile | `analytics_lab` in `~/.dbt/profiles.yml` | manual, step 8 |

### Troubleshooting

| Message | Cause |
|---|---|
| `could not create directory ... permission denied` | step 2 not applied, or folder recreated |
| `cross-database references are not implemented` | a model or query naming a different database |
| `Could not find profile named 'x'` | no block of that name in `~/.dbt/profiles.yml` |
| `timeout expired` | wrong address, or firewall |
| `Host is down` | server powered off or asleep |
| `'utf-8' codec can't decode byte 0xab` | Spanish `lc_messages` hiding the real error — decode as latin-1, or set `lc_messages = 'C'` |
