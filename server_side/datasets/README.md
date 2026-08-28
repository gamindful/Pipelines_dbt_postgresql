# Loading the credit datasets into PostgreSQL

A step-by-step guide to building the `credit_risk` database from the two CSVs
in this folder (`credit/credit_default.csv`, `credit/german_credit.csv`) —
three ways to do it, on Windows, macOS and Linux, plus what changes if you
use a GUI client instead.

**Verification status:** the Windows / terminal and Windows / Python paths
were run against this actual server while writing this guide, including the
three bugs documented below. macOS and Linux invocations follow this
project's already-established conventions (see the top-level `README.md`)
but weren't re-executed here — there's no Mac or Linux machine in this
session to run them on. `dbt seed` (Method 3) is written but untested on
every OS: this machine's `dbt` resolves to Fusion, which has no Postgres
adapter, same issue already documented for the Mac client.

For the bigger picture (why two databases, how the client/server split
works, the dbt layering) see `models/credit_risk_marts/README.md` and the
top-level `README.md`'s **Connection config** section. This file is the
hands-on companion: exact commands, exact errors, exact fixes.

## What you're building

| Source CSV | Target | Rows |
|---|---|---|
| `credit/credit_default.csv` | `credit_risk.credit_raw.credit_default` | 30,000 |
| `credit/german_credit.csv` | `credit_risk.credit_raw.german_credit` | 1,000 |

Both tables, the `credit_raw`/`analytics` schemas, and the `app_credit` role
are defined in `server_side/sql/04_credit_role_and_schema.sql`.

---

## Prerequisites (one-time, run as the `postgres` superuser)

If `credit_risk` doesn't exist yet on this server:

```powershell
# 1. the tablespace's target folder must exist and be writable by the
#    Postgres service account (NT AUTHORITY\NetworkService on this machine)
New-Item -ItemType Directory -Force -Path "C:\Users\Gamaliel\Documents\GitHub\Financial_analytics\pgdata\credit_tablespace"
icacls "C:\Users\Gamaliel\Documents\GitHub\Financial_analytics\pgdata\credit_tablespace" /grant "NT AUTHORITY\NetworkService:(OI)(CI)F"

$pgbin = "C:\Program Files\PostgreSQL\18\bin"

# without this, each psql call below prompts interactively for the postgres
# password -- easy to miss in some terminals, which looks like an auth
# failure even when the password would have been correct
$env:PGPASSWORD = "<postgres password>"

# 2. tablespace + database
& "$pgbin\psql.exe" -U postgres -h 127.0.0.1 -f "server_side\sql\03_credit_tablespace_and_db.sql"

# 3. role, schemas, tables -- pick a real password for app_credit here
& "$pgbin\psql.exe" -U postgres -h 127.0.0.1 -d credit_risk -v app_password="<choose one>" -f "server_side\sql\04_credit_role_and_schema.sql"

Remove-Item Env:\PGPASSWORD
```

Skip this section if `credit_risk` already exists — check with:
```powershell
& "$pgbin\psql.exe" -U postgres -h 127.0.0.1 -c "\l credit_risk"
```

---

<details>
<summary><b>Method 1 — Terminal (<code>psql</code> / <code>\copy</code>)</b></summary>

No Python needed. `\copy` is a **psql meta-command** — it runs client-side,
reading the CSV from whichever machine is running `psql`, and streams it to
the server over the existing connection. That means it never needs the
Postgres *service account* to have filesystem access (unlike server-side
`COPY '<path>'`, which reads the path on the machine Postgres itself runs
on) — but it does mean the CSV has to actually exist on whichever machine
you run `psql` from. On the server that's this folder directly; on a Mac or
Linux client it means `git pull`ing the repo first (`datasets/` is tracked,
not git-ignored, specifically so this works).

**Why the explicit column list, on every OS:** both tables have columns the
CSVs don't carry (`source`, `loaded_at` — both have `DEFAULT`s;
`applicant_id` — a `SERIAL`). Without naming columns, `\copy` expects the
CSV to match the table's full column count and order and fails immediately.

**Host:** `127.0.0.1` only works when `psql` runs *on* the server itself.
From a Mac or Linux client, use the LAN address, `192.168.1.69`.

#### Windows

Commands below are what actually ran, verified, on this server. `psql` is
not on `PATH` by default, hence the full path to `psql.exe`.

```powershell
$pgbin = "C:\Program Files\PostgreSQL\18\bin"
$env:PGPASSWORD = "<app_credit password>"

& "$pgbin\psql.exe" -U app_credit -h 127.0.0.1 -d credit_risk -c "\copy credit_raw.credit_default (client_id, limit_bal, sex, education, marriage, age, pay_0, pay_2, pay_3, pay_4, pay_5, pay_6, bill_amt1, bill_amt2, bill_amt3, bill_amt4, bill_amt5, bill_amt6, pay_amt1, pay_amt2, pay_amt3, pay_amt4, pay_amt5, pay_amt6, default_next_month) FROM 'E:\Win\pipelines_dbt_postgresql\server_side\datasets\credit\credit_default.csv' WITH (FORMAT csv, HEADER true)"

& "$pgbin\psql.exe" -U app_credit -h 127.0.0.1 -d credit_risk -c "\copy credit_raw.german_credit (checking_status, duration_months, credit_history, purpose, credit_amount, savings_status, employment_since, installment_rate, personal_status_sex, other_debtors, residence_since, property_type, age_years, other_installment_plans, housing, existing_credits, job, dependents, telephone, foreign_worker, credit_risk_class) FROM 'E:\Win\pipelines_dbt_postgresql\server_side\datasets\credit\german_credit.csv' WITH (FORMAT csv, HEADER true)"

Remove-Item Env:\PGPASSWORD
```

Backslash paths (`E:\Win\...`) pass through `\copy` correctly — no need to
convert to forward slashes here (unlike a tablespace `LOCATION`, which is a
SQL string literal and does need them).

**Re-run cleanly** (empties the table first, so re-running doesn't duplicate
rows):
```powershell
& "$pgbin\psql.exe" -U app_credit -h 127.0.0.1 -d credit_risk -c "TRUNCATE credit_raw.german_credit RESTART IDENTITY;"
```
This needs `app_credit` to *own* `german_credit` and its `applicant_id`
sequence, not just have `USAGE` on it — see the ownership gotcha under
Method 2 if this errors with `must be owner of sequence`.

**If running from WSL on this same machine:** don't use the WSL-visible
gateway address (`172.19.x.x`) as the host — it's unroutable from outside
the WSL VM and produces a 20-second timeout, not a clean refusal. Use the
Windows host's real LAN address, `192.168.1.69`, same as any other client
(see the top-level `README.md`, Step 3, for the full story on that one).

#### macOS

Not on `PATH` by default either, on a fresh install — `brew install
postgresql@16 && brew link --force postgresql@16` gets `psql` working (see
the top-level `README.md`'s server-side notes, or just `which psql` to check
first). Paths use forward slashes; the repo clone's location replaces
`E:\Win\...`.

```bash
export PGPASSWORD='<app_credit password>'

psql -U app_credit -h 192.168.1.69 -d credit_risk -c "\copy credit_raw.credit_default (client_id, limit_bal, sex, education, marriage, age, pay_0, pay_2, pay_3, pay_4, pay_5, pay_6, bill_amt1, bill_amt2, bill_amt3, bill_amt4, bill_amt5, bill_amt6, pay_amt1, pay_amt2, pay_amt3, pay_amt4, pay_amt5, pay_amt6, default_next_month) FROM '$HOME/path/to/pipelines_dbt_postgresql/server_side/datasets/credit/credit_default.csv' WITH (FORMAT csv, HEADER true)"

psql -U app_credit -h 192.168.1.69 -d credit_risk -c "\copy credit_raw.german_credit (checking_status, duration_months, credit_history, purpose, credit_amount, savings_status, employment_since, installment_rate, personal_status_sex, other_debtors, residence_since, property_type, age_years, other_installment_plans, housing, existing_credits, job, dependents, telephone, foreign_worker, credit_risk_class) FROM '$HOME/path/to/pipelines_dbt_postgresql/server_side/datasets/credit/german_credit.csv' WITH (FORMAT csv, HEADER true)"

unset PGPASSWORD
```

#### Linux

Client package usually isn't installed by default either:
```bash
sudo apt install postgresql-client   # Debian/Ubuntu; dnf/yum on Fedora/RHEL
```
Everything else matches macOS exactly — same `psql` binary, same POSIX
shell syntax, same `-h 192.168.1.69`:
```bash
export PGPASSWORD='<app_credit password>'
psql -U app_credit -h 192.168.1.69 -d credit_risk -c "\copy credit_raw.credit_default (...) FROM '/home/you/path/to/pipelines_dbt_postgresql/server_side/datasets/credit/credit_default.csv' WITH (FORMAT csv, HEADER true)"
unset PGPASSWORD
```

</details>

<details>
<summary><b>Method 2 — Python (<code>server_side/utils/*.py</code>)</b></summary>

The repo already ships a downloader and a loader for these datasets. Both use
`pathlib`, so the scripts themselves are identical on every OS — only how
you invoke Python and set up the venv differs.

```bash
python utils/download_credit_data.py   # UCI -> datasets/credit/*.csv (skip if you already have the CSVs)
python utils/load_credit_data.py       # CSV -> credit_raw.* (add --truncate to make reruns idempotent)
```

Connection settings come from `server_side/.env` (git-ignored). **The one
thing that does change with where you run it: `PGHOST`.** `localhost` only
works if the script runs on the server itself:
```
PGHOST=localhost      # server-side (this repo's own .env, used in this session)
PGHOST=192.168.1.69   # client-side (Mac, Linux, or any other machine on the LAN)
PGPORT=5432
PGDATABASE=credit_risk
PGUSER=app_credit
PGPASSWORD=...
```

#### Windows

```powershell
python -m venv venv
venv\Scripts\Activate.ps1
```
If `Activate.ps1` refuses to run (`cannot be loaded because running scripts
is disabled`), that's PowerShell's execution policy, not a broken venv:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```
Then, from `server_side/`:
```powershell
pip install psycopg2-binary xlrd requests
python utils\download_credit_data.py
python utils\load_credit_data.py
```
(This session ran both scripts against the system Python directly, without
a dedicated venv, since the packages were already installed — a venv is the
better default for reproducibility, per the same reasoning as the client
repo's own Step 1.)

#### macOS

Matches this project's established client convention exactly (top-level
`README.md`, Step 1):
```bash
python3 -m venv venv
./venv/bin/pip install psycopg2-binary xlrd requests
./venv/bin/python utils/download_credit_data.py
./venv/bin/python utils/load_credit_data.py
```

#### Linux

Same as macOS — both POSIX, same `venv/bin/` layout. The one Linux-specific
wrinkle: some distros ship Python without the `venv` module split out into
its own package:
```bash
sudo apt install python3-venv   # if `python3 -m venv` fails with "No module named venv"
python3 -m venv venv
./venv/bin/pip install psycopg2-binary xlrd requests
./venv/bin/python utils/download_credit_data.py
./venv/bin/python utils/load_credit_data.py
```

Verified output from this session (server-side, Windows, `PGHOST=localhost`):
```
=== credit_default -> credit_raw.credit_default ===
  30,000 rows now in credit_raw.credit_default

=== german_credit -> credit_raw.german_credit ===
  1,000 rows now in credit_raw.german_credit
```

**Three real bugs surfaced getting this to run cleanly — all fixed in this
session:**

1. **`invalid input syntax for type smallint: "1.0"`.** `xlrd` (used to read
   the source `.xls`) returns every numeric cell as a Python `float`, so
   integer-typed columns (`client_id`, `sex`, `pay_0`, ...) were written to
   the CSV as `"1.0"`, `"2.0"`, etc. — not valid input for an `INTEGER`/
   `SMALLINT` column. Fixed in `download_credit_data.py`: whole-number
   floats now collapse to plain int strings before writing the CSV. Columns
   that carry an actual fraction (there aren't any in this dataset, but the
   fix is generic) are left untouched.

2. **`... not found -- run download_credit_data.py first`, even right after
   running it.** `download_credit_data.py` writes to `datasets/credit/`,
   but `load_credit_data.py` was looking in `datasets/` directly — a stale
   path from before the `credit/` subfolder was split out to keep these CSVs
   separate from the crypto/FX ones. Fixed: `load_credit_data.py`'s
   `DATASETS_DIR` now points at `datasets/credit`.

3. **`--truncate` failing** two different ways, only on `german_credit`
   (which has a `SERIAL` primary key — `credit_default.client_id` is a plain
   `INTEGER`, so it never hit this):
   - `permiso denegado a la tabla german_credit` — `app_credit` had
     `SELECT/INSERT/UPDATE/DELETE` but not `TRUNCATE`. Fixed: granted
     `TRUNCATE`, plus `ALTER DEFAULT PRIVILEGES` so it's automatic for future
     tables in `credit_raw`.
   - `debe ser dueño de la secuencia german_credit_applicant_id_seq` — even
     with `TRUNCATE` granted, `RESTART IDENTITY` additionally needs *sequence
     ownership*, not just `USAGE`. The tables were created while connected as
     `postgres` (running `04_credit_role_and_schema.sql`), so `postgres`
     owned them despite the schema itself saying `AUTHORIZATION app_credit`
     — **ownership doesn't cascade from a schema to objects created inside
     it later.** Fixed: `ALTER TABLE ... OWNER TO app_credit` on both tables
     plus `ALTER SEQUENCE ... OWNER TO app_credit` on the German credit
     sequence, now baked into `04_credit_role_and_schema.sql` so a fresh
     `credit_risk` build doesn't need this fixed by hand again.

</details>

<details>
<summary><b>Method 3 — dbt seed</b></summary>

dbt can load small-to-medium CSVs directly as tables via `dbt seed` —
appropriate here since these files aren't huge (30K and 1K rows). This
method was **written but not executed** in this session: the `dbt` on
this Windows machine resolves to `dbt-fusion` (`~/.local/bin/dbt`), which —
same as documented for the Mac client in this repo's top-level README,
Step 7 — has no Postgres adapter. Run this from a `dbt-core` venv instead,
per this project's established client/server split.

Add a seed path pointing at this folder, in `dbt_project.yml`:
```yaml
seed-paths: ["server_side/datasets/credit"]
```

#### Windows

```powershell
venv\Scripts\dbt.exe seed --profile credit_risk
```
`profiles.yml` lives at `%USERPROFILE%\.dbt\profiles.yml`
(`C:\Users\<you>\.dbt\profiles.yml`) — the direct equivalent of `~/.dbt/` on
macOS/Linux, just spelled differently. If a bare `dbt` resolves to Fusion
here too (check with `dbt --version` — Fusion reports `dbt-fusion x.y.z`,
core reports `Core: x.y.z`), call the venv's `dbt.exe` explicitly as above
rather than relying on `PATH`. And if you're running from WSL on this same
box: same LAN-address-not-WSL-gateway rule as Method 1 applies to dbt's
connection too.

#### macOS

The convention this project already uses everywhere else (top-level
`README.md`, Steps 1, 6, 7 — including neutralizing the same Fusion-
shadowing problem noted above, on the client side):
```bash
./venv/bin/dbt seed --profile credit_risk
```
`profiles.yml` at `~/.dbt/profiles.yml` — see
`models/credit_risk_marts/README.md` §5 for the exact block this profile
needs.

#### Linux

Identical to macOS — dbt-core is POSIX-consistent, same `venv/bin/` layout,
same `~/.dbt/profiles.yml` location:
```bash
./venv/bin/dbt seed --profile credit_risk
```
(Not executed in this session on any OS — Windows had only the Fusion
binary available, and there's no Linux machine in this setup to verify
against. The macOS invocation is the one already proven to work elsewhere in
this repo; Linux should be identical since dbt-core has no OS-specific
behavior here, but treat it as unverified until you've actually run it.)

**This does not replace the Python loader, and lands data somewhere
different on purpose.** `dbt seed` creates its tables in whatever schema the
active profile targets — for `credit_risk`, that's `analytics` (see the
profile's `schema: analytics`), **not** `credit_raw`. That's a feature, not
a gap: this project's design (`models/credit_risk_marts/README.md` §3) is
explicit that "the loader owns `credit_raw` and dbt owns `analytics` ...
keeping them apart means a bad `dbt run` can never destroy the ingested
source data." A seed pointed at `credit_raw` would fight that boundary.
Treat `dbt seed` here as a quick way to get these CSVs queryable through dbt
for exploration or testing — the tracked, idempotent path into `credit_raw`
is still `load_credit_data.py`.

If you seed anyway and want type control instead of dbt's inferred types,
override it per-seed in `dbt_project.yml`:
```yaml
seeds:
  pipelines_dbt_postgresql:
    credit_default:
      +column_types:
        client_id: int
        default_next_month: smallint
```

</details>

---

<details>
<summary><b>If you load through a different client (pgAdmin, DBeaver, ...)</b></summary>

The commands above are specific to `psql` and `psycopg2`. A GUI client's
import wizard is a genuinely different code path, not just a different
button for the same `COPY` — a few things behave differently and are worth
checking explicitly before trusting an import as correct. This applies the
same way regardless of which OS the GUI runs on; only getting the tool
installed differs:

- **Windows:** pgAdmin 4 and DBeaver both ship as native installers —
  `winget install PostgreSQL.pgAdmin` / `winget install dbeaver.dbeaver`,
  or download directly.
- **macOS:** `brew install --cask pgadmin4` / `brew install --cask
  dbeaver-community`.
- **Linux:** pgAdmin is commonly run via its official Docker image rather
  than a native package, since distro packaging is inconsistent
  (`docker run -p 5050:80 ... dpage/pgadmin4`); DBeaver ships `.deb`/`.rpm`,
  or `sudo snap install dbeaver-ce`.

- **Type inference happens in the client, not from your existing table.**
  pgAdmin's *Import/Export Data* and DBeaver's *Data Transfer* both default
  to inspecting the CSV and guessing column types — they don't necessarily
  respect the types already defined on `credit_raw.credit_default`. If you
  point either tool at *creating* a new table rather than *appending* to the
  existing one, you can silently end up with a different schema than
  `04_credit_role_and_schema.sql` defines (e.g. `NUMERIC` instead of
  `SMALLINT`, no `CHECK` constraints, no foreign key from `price_history`-
  style tables). **Load into the existing table** (append mode), don't let
  the wizard create it.

- **Column order/count still has to match, or be mapped explicitly.** Same
  underlying issue as the explicit column list in Method 1 — these tables
  carry `source`/`loaded_at`/`applicant_id` that aren't in the CSV. Most GUI
  importers offer a column-mapping step for exactly this; skipping past it
  with defaults is the most common way an import silently fails or nulls out
  the wrong columns.

- **The `"1.0"`-style integer problem still applies**, and a GUI tool may
  handle it more forgivingly (and less visibly) than `psql` did. Some
  importers auto-cast a text `"1.0"` into a target `SMALLINT` by rounding
  rather than raising `invalid input syntax` outright — which means a GUI
  load could "succeed" while doing something the terminal method never
  would have allowed silently. If you use a GUI tool, load the *already
  regenerated* `credit_default.csv` in this folder (integers, no `.0`
  suffix) rather than assuming the tool will handle the raw UCI format
  gracefully.

- **Both tools run client-side, like `\copy`, not server-side.** pgAdmin's
  and DBeaver's import read the CSV from the machine running the GUI, then
  stream it over the connection — same topology as Method 1, not the
  server-filesystem-reading `COPY '<path>'` form. No special server-side
  file access is needed either way.

- **Set the import encoding explicitly to UTF-8.** These CSVs are written
  UTF-8; GUI import dialogs often default to the OS locale instead of
  detecting the file's encoding. This server in particular runs
  `lc_messages = Spanish_Mexico.1252` (documented in the top-level README's
  Step 4), so don't assume the tool's default matches — pick UTF-8
  explicitly in the import dialog if it's offered.

</details>

---

## Verify

Regardless of which method you used:

```sql
SELECT count(*) FROM credit_raw.credit_default;   -- expect 30000
SELECT count(*) FROM credit_raw.german_credit;     -- expect 1000

SELECT default_next_month, count(*) FROM credit_raw.credit_default GROUP BY 1;
SELECT credit_risk_class,  count(*) FROM credit_raw.german_credit  GROUP BY 1;
```
