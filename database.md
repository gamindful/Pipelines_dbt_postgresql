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

Everything in this section runs directly on that machine, in a regular
PowerShell window — no particular working directory required, every path
below is absolute.

`psql` is installed at `C:\Program Files\PostgreSQL\18\bin\psql.exe` and is
**not** on `PATH` by default. Either add that folder to `PATH` once, or call
the full path every time.

> **`pgdata` here is not the server's real data directory.** The running
> `postgresql-x64-18` service (confirmed via `Get-CimInstance Win32_Service`)
> uses `C:\Program Files\PostgreSQL\18\data` as its actual `PGDATA` — that's
> where the EDB installer put it, and it's not something you create or manage
> by hand. The `...\postgres_local_server\pgdata\` folder below is just a
> tablespace target you create yourself; the name is coincidental. It is
> **not** nested inside the real data directory, which is what actually
> matters — Postgres refuses a tablespace location that is.

### Step 1 — Create the tablespace folder

```powershell
mkdir "C:\Users\Gamaliel\Documents\G\databases\postgres_local_server\pgdata\analytics_tablespace"
```

### Step 2 — Grant the service account access to it

Postgres runs as `NT AUTHORITY\NetworkService`, not as the logged-in user
(confirmed via the service's `StartName`). Skipping this makes
`CREATE TABLESPACE` fail with a permissions error.

```powershell
icacls "C:\Users\Gamaliel\Documents\G\databases\postgres_local_server\pgdata\analytics_tablespace" /grant "NT AUTHORITY\NetworkService:(OI)(CI)F"
```

> This grant is lost if the folder is ever deleted and recreated. Reapply it
> after any teardown.

### Step 3 — Create the tablespace and database

Connect to `postgres` — `analytics_lab` does not exist yet. Neither statement
can run inside a transaction block.

```powershell
psql -U postgres -d postgres `
  -c "CREATE TABLESPACE analytics_tablespace LOCATION 'C:/Users/Gamaliel/Documents/G/databases/postgres_local_server/pgdata/analytics_tablespace';" `
  -c "CREATE DATABASE analytics_lab WITH TABLESPACE = analytics_tablespace ENCODING = 'UTF8';"
```

### Step 4 — Generate a password for the application role

```powershell
$pw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | % {[char]$_}); $pw
```

Copy the output — it is needed in steps 5 and 8.

### Step 5 — Create the application role

Passed as a psql variable so it never appears inside a `.sql` file.

> **`-c` cannot be used here.** On this Windows/psql 18 setup, `:'var'` and
> even bare `:var` interpolation silently fails to trigger when the SQL is
> passed as a `-c` command-line argument — the colon reaches the parser
> unsubstituted and you get `error de sintaxis en o cerca de «:»` /
> `syntax error at or near ":"`, no matter how or where `$pw` was set.
> Confirmed with a minimal `SELECT :app_password;` test. The exact same text
> read from a file via `-f` works correctly, so that's the form to use —
> and it still keeps the password out of the `.sql` file itself, since only
> the variable *reference* goes on disk, briefly, in `$env:TEMP`.

```powershell
@'
CREATE ROLE gama WITH LOGIN PASSWORD :'app_password';
'@ | Out-File -Encoding utf8 "$env:TEMP\create_gama_role.sql"

psql -U postgres -d postgres -v app_password="$pw" -f "$env:TEMP\create_gama_role.sql"
Remove-Item "$env:TEMP\create_gama_role.sql"
```

### Step 6 — Create the first schema: `credit_risk`

```powershell
psql -U postgres -d analytics_lab `
  -c "CREATE SCHEMA credit_risk AUTHORIZATION gama;" `
  -c "GRANT USAGE, CREATE ON SCHEMA credit_risk TO gama;"
```

### Step 7 — Let dbt create its own schemas

```powershell
psql -U postgres -d analytics_lab `
  -c "GRANT CREATE ON DATABASE analytics_lab TO gama;" `
  -c "ALTER ROLE gama SET search_path = credit_risk, staging, marts, public;"
```

Verify — `credit_risk` owned by `gama`, and nothing else yet:

```powershell
psql -U postgres -d analytics_lab -c "\dn" -c "\du gama"
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
      user: gama
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

**Next:** source tables and the loader, then the first staging model. Where
the loader/extraction code lives and runs from is not decided yet — fill in
the "Loader / extraction scripts" row in the reference table below once it
is.

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
| Role | `gama` | psql, step 5 |
| First schema | `credit_risk` | psql, step 6 |
| Model schemas | `staging`, `intermediate`, `marts` | dbt, on first run |
| Profile | `analytics_lab` in `~/.dbt/profiles.yml` | manual, step 8 |

| Path | What it is | Machine |
|---|---|---|
| `C:\Program Files\PostgreSQL\18\bin\psql.exe` | psql client binary (run steps 3, 5–7) | Windows server |
| `C:\Program Files\PostgreSQL\18\data` | Real `PGDATA` — installed by EDB, not created by hand | Windows server |
| `C:\Users\Gamaliel\Documents\G\databases\postgres_local_server\pgdata\analytics_tablespace` | Tablespace target folder, created in step 1 | Windows server |
| `/Users/gamaliel/Documents/G/DS/pipelines/Pipelines_dbt_postgresql` | dbt project — steps 9–10 | macOS client |
| Loader / extraction scripts | **TBD** — not designed yet, see *Where this stops* below | — |

### Troubleshooting

| Message | Cause |
|---|---|
| `could not create directory ... permission denied` | step 2 not applied, or folder recreated |
| `cross-database references are not implemented` | a model or query naming a different database |
| `Could not find profile named 'x'` | no block of that name in `~/.dbt/profiles.yml` |
| `timeout expired` | wrong address, or firewall |
| `Host is down` | server powered off or asleep |
| `'utf-8' codec can't decode byte 0xab` | Spanish `lc_messages` hiding the real error — decode as latin-1, or set `lc_messages = 'C'` |
