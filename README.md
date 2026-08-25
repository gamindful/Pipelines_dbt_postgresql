# Pipelines_dbt_postgresql

dbt models targeting PostgreSQL 18.6 on a LAN server.

## Setup

    python3 -m venv venv
    ./venv/bin/pip install -r requirements.txt

Copy the profile block from `profiles.example.yml` into `~/.dbt/profiles.yml`
and fill in your own host and credentials. dbt reads it from there, not from
this repo -- which is why no credential is committed.

## Use

    ./venv/bin/dbt debug     # verify the connection
    ./venv/bin/dbt run       # build models
    ./venv/bin/dbt test      # validate them

---

# How this environment was built

A record of every configuration change that took this project from nothing to a
working `git push`. Each step expands.

**Topology:** a macOS client running dbt, reaching a Windows machine running
PostgreSQL over the local network.

```
CLIENT · macOS                          SERVER · Windows
────────────────                        ─────────────────
VS Code + tasks.json                    PostgreSQL 18.6
venv/bin/dbt   (dbt-core 1.12.3) ──▶    192.168.1.69:5432
venv/bin/python3.13                     database: local
~/.dbt/profiles.yml (credentials)       schema: public
```

## Paths that had to change

The single most important table here. Three different binaries called `dbt`
and two called `python3` existed on this machine; getting the right one in each
place was most of the work.

| Role | Path | Notes |
|---|---|---|
| **Global Python** | `/Library/Frameworks/Python.framework/Versions/3.13/bin/python3` | Used **once**, only to create the venv. Nothing else uses it. |
| **Local Python** | `<project>/venv/bin/python3.13` | Everything runs on this. Pinned in VS Code. |
| **Local dbt** | `<project>/venv/bin/dbt` | dbt-core 1.12.3 with the `postgres` adapter. The one that works. |
| **Fusion dbt** *(neutralized)* | `~/.local/bin/dbt` → renamed `dbt-fusion` | 247 MB standalone binary. Was shadowing dbt-core and has **no Postgres adapter**. |
| **Credentials** | `~/.dbt/profiles.yml` | Deliberately outside the repo. Never committed. |

---

<details>
<summary><b>Step 1 — Create the local Python environment</b></summary>

The global Python is used exactly once, to bootstrap an isolated environment.
After this, nothing in the project touches system Python again.

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/Pipelines_dbt_postgresql
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
```

`requirements.txt` pins the versions so the environment is reproducible:

```
dbt-core==1.12.3
dbt-postgres==1.11.0
psycopg2-binary==2.9.12
```

Verify:

```bash
./venv/bin/dbt --version     # Core: 1.12.3
```

</details>

<details>
<summary><b>Step 2 — Make the Windows server accept LAN connections</b></summary>

Four conditions must **all** be true. A failure in any one looks identical from
the client: a connection that hangs until timeout.

1. `postgresql.conf` → `listen_addresses = '*'` (default is `localhost` only)
2. `pg_hba.conf` → `host all all 192.168.1.0/24 scram-sha-256`
3. Windows Firewall → inbound TCP 5432 allowed
4. Network profile → **Private**, not Public

```powershell
Get-NetConnectionProfile          # must NOT say Public
New-NetFirewallRule -DisplayName "PostgreSQL 5432" -Direction Inbound `
  -Protocol TCP -LocalPort 5432 -Action Allow
Restart-Service postgresql-x64-18
```

`psql` is not on the Windows `PATH` by default:

```powershell
$env:Path += ";C:\Program Files\PostgreSQL\18\bin"
```

</details>

<details>
<summary><b>Step 3 — Use the LAN address, not the WSL gateway</b></summary>

The original configuration pointed at **`172.19.128.1`**, which produced a
20-second timeout on every attempt.

That address is the **WSL2 gateway**. It resolves to the Windows host *only from
inside a WSL virtual machine*. From any other device it is unroutable — packets
leave, hit the default gateway, and are dropped. Hence timeout rather than a
refusal.

The correct address is the machine's **LAN address**, found on Windows with:

```powershell
ipconfig | findstr /i "IPv4"      # take the 192.168.1.x, ignore 172.19.x
```

Here that is **`192.168.1.69`**.

**Reading failures:** `timeout` = wrong address or firewall. `connection
refused` = host reached, Postgres not listening there. `Host is down` = the
machine is off or asleep. `auth error` = networking already solved.

</details>

<details>
<summary><b>Step 4 — Create the database</b></summary>

`dbt debug` reported a UTF-8 codec crash rather than a useful message. The real
error, once decoded, was `no existe la base de datos «local»` — the database
simply did not exist.

```powershell
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -c 'CREATE DATABASE "local";'
```

**Why the error was unreadable:** the server runs
`lc_messages = Spanish_Mexico.1252`. Its error text contains `«»` guillemets
(`0xAB`/`0xBB`), which are invalid UTF-8. psycopg2 assumes UTF-8, raises
`'utf-8' codec can't decode byte 0xab`, and the real cause disappears.

To decode such an error in Python:

```python
except UnicodeDecodeError as e:
    print(e.object.decode("latin-1", errors="replace"))
```

Permanent fix on the server — affects message text only, not data or collation:

```sql
ALTER SYSTEM SET lc_messages = 'C';
SELECT pg_reload_conf();
```

</details>

<details>
<summary><b>Step 5 — Configure the connection in <code>~/.dbt/profiles.yml</code></b></summary>

This file lives **outside the repository**. That is the entire reason this
project is safe to publish: the models, config and tasks are committed; the
host and password are not.

```yaml
pipelines_dbt_postgresql:
  target: dev
  outputs:
    dev:
      type: postgres
      host: 192.168.1.69
      port: 5432
      user: postgres
      pass: '...'
      dbname: local
      schema: public
      threads: 4
      connect_timeout: 5      # fail in 5s instead of 20 while debugging
```

`dbt_project.yml` refers to it **by name only**:

```yaml
profile: 'pipelines_dbt_postgresql'
```

No `.sql` file and no committed config contains a server address or credential.

</details>

<details>
<summary><b>Step 6 — Verify the connection</b></summary>

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/Pipelines_dbt_postgresql
./venv/bin/dbt debug
```

Expect `Connection test: [OK connection ok]` and `All checks passed!`.

**Always run dbt from the project directory.** dbt resolves `dbt_project.yml`
from the working directory and does not search subdirectories. Running from the
parent produced `Internal Error: Profile should not be None` — a cryptic message
caused by dbt having no project file to tell it which profile to use, made worse
by several profiles existing in `profiles.yml`.

Override when needed:

```bash
./venv/bin/dbt debug --project-dir Pipelines_dbt_postgresql
```

</details>

<details>
<summary><b>Step 7 — Stop the global Fusion binary from shadowing dbt-core</b></summary>

A separate 247 MB **dbt Fusion** binary sat at `~/.local/bin/dbt`. Because
`~/.local/bin` is on `PATH`, any non-activated shell resolved `dbt` to Fusion —
which supports snowflake, bigquery, databricks, redshift, duckdb, salesforce and
clickhouse, **but not postgres**:

```
[error] [InvalidConfig (dbt1005)]: The 'postgres' adapter is not yet
supported by dbt Fusion.
```

Rename it. Fusion stays installed and runnable under a name that cannot be
picked up by accident:

```bash
mv ~/.local/bin/dbt ~/.local/bin/dbt-fusion
```

Check which binary a shell would use:

```bash
type -a dbt
```

</details>

<details>
<summary><b>Step 8 — Pin the Python interpreter in VS Code</b></summary>

`.vscode/settings.json` — note the **absolute** path:

```json
{
  "python.defaultInterpreterPath": "/Users/gamaliel/Documents/G/DS/pipelines/Pipelines_dbt_postgresql/venv/bin/python3.13",
  "python.terminal.activateEnvironment": true
}
```

Then **Cmd+Shift+P → Python: Select Interpreter**, and **open a new terminal** —
terminals opened beforehand keep their old environment permanently.

Confirm both resolve inside the venv:

```bash
which python3; which dbt
```

*This file is gitignored* — it hard-codes a machine-specific path and is useless
on any other computer.

</details>

<details>
<summary><b>Step 9 — Run dbt from VS Code with a task, not the extension button</b></summary>

The dbt Labs extension (`dbtlabsinc.dbt`) **requires the Fusion engine**. It
ignores `dbt.dbtPath` and always launches Fusion, which cannot speak to
Postgres. It states this outright:

> This extension requires the dbt Fusion engine, and the dbt binary at
> `/Users/gamaliel/.local/bin/dbt` can't run `dbt lsp`.

No setting changes that. Use a task instead — `.vscode/tasks.json`:

```json
{
  "label": "dbt: run current model",
  "type": "shell",
  "command": "${workspaceFolder}/venv/bin/dbt",
  "args": ["run", "--select", "${fileBasenameNoExtension}"],
  "group": { "kind": "build", "isDefault": true }
}
```

**Cmd+Shift+B** runs the open model. Selection is by *model name*, not file
path, so one task serves every `.sql` file in `models/`.

**The `${workspaceFolder}` trap:** VS Code expands that variable in
`tasks.json` and `launch.json`, but **not** in arbitrary extension settings.
Using it in `dbt.dbtPath` silently produced a literal, unresolvable path — which
is why the extension fell back to Fusion. Extension settings need absolute
paths; tasks do not.

For a working button, lineage and previews on dbt-core, use **dbt Power User**
(`innoverio.vscode-dbt-power-user`, by Altimate AI) instead.

</details>

<details>
<summary><b>Step 10 — Open the project folder as the workspace root</b></summary>

Open **`Pipelines_dbt_postgresql`** itself, never the parent. Three separate
mechanisms depend on it:

1. **dbt** resolves `dbt_project.yml` from the working directory.
2. **VS Code** reads `.vscode/` only at the workspace root — open the parent and
   your tasks and interpreter pin vanish silently.
3. **`${workspaceFolder}`** resolves to whatever was opened, so tasks would
   point at a `venv/` that does not exist there.

For several projects at once, use *File → Add Folder to Workspace* — a
multi-root workspace keeps each folder's `.vscode/` active.

</details>

<details>
<summary><b>Step 11 — Write models</b></summary>

A dbt model is just a `SELECT`. dbt supplies the connection and wraps it in
`create view as`. Models contain **no** connection details.

`models/stg_tables.sql`:

```sql
select table_schema, table_name, table_type
from information_schema.tables
where table_schema not in ('pg_catalog', 'information_schema')
```

`models/table_summary.sql` — `ref()` builds the DAG and the run order:

```sql
{{ config(materialized='table') }}

select table_schema, count(*) as table_count
from {{ ref('stg_tables') }}
group by table_schema
```

```bash
./venv/bin/dbt run
./venv/bin/dbt show --select table_summary --limit 20
```

</details>

<details>
<summary><b>Step 12 — Publish to GitHub</b></summary>

`.gitignore` must exclude the venv, build artifacts and any credential file:

```
target/
dbt_packages/
logs/
venv/
profiles.yml
.vscode/settings.json
.DS_Store
```

A plain `git push` to a repository that does not exist yet fails with
`repository not found` — GitHub returns 404 rather than 403 so it does not leak
whether private repositories exist. The `gh` CLI creates and pushes in one step:

```bash
brew install gh
gh auth login
git remote remove origin
gh repo create Pipelines_dbt_postgresql --private --source=. --remote=origin --push
```

GitHub disabled password authentication for HTTPS in 2021, so the manual route
needs a Personal Access Token with the `repo` scope — `gh` avoids that entirely.

Always confirm before pushing:

```bash
git status --short                                     # nothing unexpected staged
grep -rn "<your-password>" . --exclude-dir=.git --exclude-dir=venv
```

</details>

<details>
<summary><b>Step 13 — Keep local and remote in sync</b></summary>

The ongoing loop:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/Pipelines_dbt_postgresql
git add -A
git status --short          # review before committing
git commit -m "..."
git push
```

Confirm the two match — no `ahead`/`behind`, empty diff:

```bash
git fetch && git status -sb && git diff origin/main --stat
```

If the remote also changed, rebase local work on top before pushing:

```bash
cd /Users/gamaliel/Documents/G/DS/pipelines/Pipelines_dbt_postgresql && git pull --rebase && git push
```

</details>
