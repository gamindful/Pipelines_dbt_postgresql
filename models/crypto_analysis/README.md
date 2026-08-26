# Analytics Engineer Portfolio Track

Five financial-data projects that between them exercise all seven domains of the
**dbt Analytics Engineering Certification**, built on the Postgres server this
repository already connects to. Each one ends in something showable — not an
exercise to delete.

| | |
|---|---|
| **Questions** | 65 |
| **Duration** | 2 hrs |
| **Passing score** | 65% |
| **Price** | $200 |
| **Tests dbt version** | 1.11 |
| **Recommended** | SQL proficiency + ~6 months dbt experience |
| **Languages** | English, Japanese, Spanish, French, Portuguese |

> This repo runs **dbt-core 1.12.3**, the exam tests **1.11**. Nothing in the
> track depends on the gap, but check which version introduced a behaviour
> before assuming it is examinable. Deprecation warnings you see locally — such
> as generic-test arguments needing an `arguments:` block — are 1.12 tightening,
> not 1.11 syntax.

---

## Coverage

The seven domains are **not** a sequence — they are a checklist to cover. The
five projects **are** a sequence, each depending on the last. Read down a column
to see what a project teaches, across a row to confirm nothing is thin.

| Exam domain | 1 | 2 | 3 | 4 | 5 |
|---|:-:|:-:|:-:|:-:|:-:|
| **Developing & optimizing dbt models**<br/><sub>materializations, DRY, DAG shape, incremental strategies, grants, `--empty`, microbatch</sub> | ● | ● | ○ | ● | ○ |
| **Managing model governance**<br/><sub>contracts, model versions, deprecation, YAML constraints</sub> | · | · | ● | ○ | ○ |
| **Debugging data modeling errors**<br/><sub>reading logs, compiled code, `.yml` compilation errors, behaviour flags</sub> | ● | ○ | ○ | ○ | ● |
| **Troubleshooting & optimizing pipelines**<br/><sub>DAG failure points, `dbt clone`</sub> | · | ○ | · | ○ | ● |
| **Implementing dbt tests**<br/><sub>generic, singular, custom generic; source assumptions</sub> | ● | ○ | ● | ○ | ○ |
| **External dependencies**<br/><sub>exposures, source freshness</sub> | · | ○ | · | ● | ○ |
| **Leveraging dbt state**<br/><sub>state selection, deferral, `dbt retry`</sub> | · | ● | · | ○ | ● |

● primary focus &nbsp;&nbsp; ○ practised in passing &nbsp;&nbsp; · not covered

---

## The five projects

Budget roughly two weeks each working evenings. The last is deliberately lighter
on new SQL and heavier on operations.

### 1 · Credit Risk Marts

**Data:** UCI *Default of Credit Card Clients* (Taiwan) + *Statlog German Credit*
**Covers:** materializations · DRY / modularity · generic + singular tests · docs · grants

The foundation project. Two credit datasets with genuinely different shapes — one
Excel with a doubled header, one headerless and space-delimited — force a real
staging layer instead of `select *`.

- Write explicit casts in staging. Generate the scaffold rather than typing it (see *Generating models* below), then correct types by hand.
- Build `int_` models for credit-utilisation and payment-history logic used by more than one mart.
- Write one singular test a business person would recognise — no client has a negative credit limit.
- Add a custom generic test taking a `column_name` argument so it applies to both datasets.
- Turn on the `grants` config for marts; confirm a reader role can select but not write.

**Ships as:** a documented DAG with green tests, browsable via `dbt docs serve`.

### 2 · Campaign Funnel, Incrementally

**Data:** UCI *Bank Marketing* (Portuguese retail bank, ~45k contacts)
**Covers:** incremental strategies · snapshots · state selection · `dbt retry` · `--empty`

Large enough that a full refresh gets annoying — which is the point. Incremental
logic stops being theoretical here.

- Load in two passes so the incremental branch runs on real new rows, not a synthetic `where 1=0`.
- Implement the same model with `append`, `delete+insert` and `merge`; time each and write down which you would defend in review.
- Add a YAML snapshot tracking campaign outcome changes over time.
- Validate logic without touching data using `dbt run --empty`; practise `dbt retry` after a deliberate failure.
- Save a production `manifest.json` and run `--select state:modified+` against it.

**Ships as:** a written comparison of the three incremental strategies with real timings from your server.

### 3 · Bankruptcy Signals Under Contract

**Data:** UCI *Polish Companies Bankruptcy* + *Taiwanese Bankruptcy Prediction*
**Covers:** model contracts · constraints · model versions · deprecation · `dbt_expectations`

Two markets, ~160 financial ratios between them, no shared column naming.
Governance stops feeling bureaucratic the moment a downstream consumer depends on
a shape you might change.

- Put `contract: enforced` on the shared mart; watch a deliberate type change fail at build time rather than in production.
- Declare `not_null` and `primary_key` constraints in YAML. Note which Postgres actually enforces versus which dbt only asserts.
- Ship `v1`, then `v2` with a renamed column, keeping both live and marking `v1` deprecated.
- Use `dbt_expectations` for distribution checks a plain `not_null` would miss.

**Ships as:** a versioned, contracted mart plus a short migration note for the imaginary consumer of `v1`.

### 4 · Market Data & External Dependencies

**Data:** Numerai or DrivenData *(account required)*
**Covers:** source freshness · exposures · microbatch · packages

The first dataset that actually changes. Numerai publishes new eras on a
schedule, so freshness thresholds and time-partitioned incremental logic have
something real to bite on.

- Download manually — these are gated. Never commit the data.
- Stamp a `_loaded_at` column at ingest; `source freshness` cannot be configured without one.
- Set `warn_after` / `error_after` against it and let one deliberately go stale.
- Build a `microbatch` incremental model partitioned by era; reprocess a single window without a full refresh.
- Declare an `exposure` for a notebook or dashboard so the DAG shows who breaks if a model changes.

**Ships as:** a freshness-monitored pipeline whose lineage graph reaches past dbt into a named consumer.

### 5 · Operating the Pipeline

**Data:** everything already built
**Covers:** `dbt clone` · deferral · DAG failure points · behaviour flags · compiled code

No new datasets. The capstone that turns four projects into one system, and it
maps to the two domains people most often fail: pipeline troubleshooting and
state.

- Add a `prod` target, then use `dbt clone` to stand up a dev environment without recomputing anything.
- Run with `--defer` against the prod manifest so unbuilt models resolve upstream instead of failing.
- Break a model on purpose mid-DAG; practise reading the failure back to a root cause from `target/compiled/`.
- Write the whole thing up as the repository README — what it does, how to run it, what you would change next.

**Ships as:** a repo someone else could clone and run against their own Postgres in under ten minutes.

---

## Data sources

The distinction that matters for a public portfolio is not quality — it is
whether you are allowed to commit the bytes.

| Source | What is there for finance | Access | Commit data? |
|---|---|---|---|
| **UCI ML Repository**<br/><sub>archive.ics.uci.edu</sub> | Credit default, German credit, bank marketing, two bankruptcy sets. Small, clean, classic. | open | Yes — CC BY 4.0, small extracts as seeds |
| **Hugging Face**<br/><sub>huggingface.co</sub> | Financial sentiment, filings, some market series. Direct parquet URLs. | open | Check each dataset card — licences vary |
| **Numerai**<br/><sub>numer.ai</sub> | Obfuscated global equity features on a real schedule. The best "live" source here. | account | **No** — terms forbid redistribution |
| **DrivenData**<br/><sub>drivendata.org</sub> | Financial-inclusion and credit competition tracks. | account | **No** — per-competition terms |
| **DataSource**<br/><sub>datasource.ai</sub> | Smaller finance competitions; useful for variety. | account | **No** |
| **CodaLab**<br/><sub>codalab.org</sub> | Research benchmarks. Thin on finance — treat as opportunistic. | account | **No** |
| **Google Dataset Search**<br/><sub>datasetsearch.research.google.com</sub> | An index, not a host. Find a dataset, then go to its actual host. | open | n/a |

> **Never commit raw data, even when licensing allows it.** GitHub hard-rejects
> files over 100 MB, and a repo full of CSVs is the clearest signal to a reviewer
> that no pipeline exists. Commit the loading recipe instead — the recipe is the
> artifact. Small permissively-licensed extracts belong in `seeds/`, which is
> what seeds are for.

---

## Working in this repo

Everything runs against the server described in the [root README](../README.md).

```bash
cd dbt_config_repo
source venv/bin/activate

dbt debug                    # verify the connection first
dbt run                      # build models
dbt test                     # validate them
dbt docs generate && dbt docs serve
```

In VS Code, **Cmd+Shift+B** builds whichever model is open. Do not use the dbt
Labs extension button — it requires the Fusion engine, which has no Postgres
adapter. Root README, Step 9 covers this.

### Generating models instead of typing them

A 95-column raw table is not worth hand-typing, and a typo in a cast list fails
silently. Generate the scaffold from the warehouse, then fix the types by hand —
this is the workflow real teams use.

```bash
dbt deps                     # after adding codegen to packages.yml
dbt run-operation generate_source --args '{"schema_name":"raw","database":"local"}'
dbt run-operation generate_base_model --args '{"source_name":"raw","table_name":"credit_default"}'
```

### Packages worth adding

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.3.0", "<2.0.0"]
  - package: dbt-labs/codegen
    version: [">=0.13.0", "<0.15.0"]
  - package: metaplane/dbt_expectations
    version: [">=0.10.0", "<0.11.0"]
```

### Suggested layout as the track grows

```
models/
  staging/        views, 1:1 with a source, cast + rename only
  intermediate/   ephemeral, reusable business logic, never exposed
  marts/          tables, what a human or BI tool actually queries
```

Staging does exactly four things: **cast**, **rename**, light cleanup, and
nothing else. No joins, no aggregation, no business logic — those belong
downstream. Name them `stg_<source>__<entity>.sql`.
