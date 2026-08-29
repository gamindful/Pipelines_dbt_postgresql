# Local GenBI Assistant

A fully local, privacy-preserving natural-language BI assistant built on **WrenAI**, a locally-hosted LLM (via **Ollama**), and your existing **PostgreSQL** instance. Nothing leaves the host except a one-time model download.

Designed for constrained hardware: no dedicated GPU, ≤16GB RAM, HDD (not SSD) storage, running under WSL2 on Windows Server.

## What this is

- **WrenAI** — the context/execution layer: semantic model (MDL), local memory index, governed SQL planning, dry-plan validation, execution, and dashboard generation.
- **A local agent** (LangChain + `wren-langchain`) — the two pieces WrenAI deliberately leaves to "whatever agent you bring": intent parsing (understanding the question) and writing the final natural-language summary. Backed by a model served locally through Ollama.
- **PostgreSQL** — your existing database, used as-is, no migration.

## Architecture

```
┌───────────────────────────────────────────┐
│ Agent  (LangChain + wren-langchain)        │
│  · parses the question                     │
│  · writes the final NL summary             │
└─────────────────────┬───────────────────────┘
                       │
┌──────────────────────▼──────────────────────┐
│ Ollama  (local inference, CPU)                │
│  · chat model (e.g. qwen3:8b)                 │
│  · embedding model (nomic-embed-text)         │
└──────────────────────┬──────────────────────┘
                       │
┌──────────────────────▼──────────────────────┐
│ WrenAI CLI / engine                           │
│  · MDL · local memory (LanceDB) · dry-plan    │
│  · execute · dashboard build                  │
└──────────────────────┬──────────────────────┘
                       │
┌──────────────────────▼──────────────────────┐
│ PostgreSQL  (existing, native on host)        │
└───────────────────────────────────────────────┘
```

Recommended host setup: **WSL2** (Ubuntu) hosting Ollama and the WrenAI CLI, talking to PostgreSQL running natively on the Windows host. See [Hardware notes](#hardware-notes) below.

## Project structure

```
local-genbi-assistant/
├── README.md
├── requirements.txt
├── .env.example              # LLM endpoint, DB connection, model names, telemetry flag
├── config/
│   └── wren/                 # WrenAI project
│       ├── project.yml
│       ├── models/           # MDL: tables, columns, relationships
│       └── knowledge/
│           ├── rules/        # business definitions, default filters, approved joins
│           └── sql/          # confirmed question -> SQL pairs (memory seed)
├── agent/
│   ├── main.py                # agent entrypoint (LangChain + wren-langchain + ChatOllama)
│   └── prompts.py
├── scripts/
│   ├── setup_wsl.sh           # enable/verify WSL2, install Ollama + wren CLI
│   ├── pull_models.sh         # `ollama pull` for chat + embedding models
│   └── serve_dashboard.sh     # self-host a generated GenBI dashboard (see below)
└── dashboards/                # output of GenBI builds — served locally, not deployed to the cloud
```

## Setup

1. **Enable WSL2** on the host (Windows Server 2022 "SAC" build or Windows Server 2025 — WSL2 isn't included in 2022 LTSC by default). Install an Ubuntu distribution inside it.
2. Inside WSL2, install **Ollama** natively, then pull the models listed at the bottom of `requirements.txt`.
3. Inside WSL2: `pip install -r requirements.txt`.
4. Run `wren skills get onboarding` and connect it to PostgreSQL — reachable from WSL2 over the network with no extra configuration.
5. Point `agent/main.py` at the local Ollama endpoint (`http://localhost:11434`) via `ChatOllama`, e.g.:

   ```python
   from langchain_ollama import ChatOllama
   from wren_langchain import WrenTool  # wraps the wren CLI as a LangChain tool

   llm = ChatOllama(model="qwen3:8b", base_url="http://localhost:11434")
   tools = [WrenTool(project_dir="config/wren")]
   # ... wire llm + tools into your LangChain/LangGraph agent
   ```

## Running the agent from a remote client (e.g. a MacBook on the LAN)

Everything above assumes Ollama and the agent run on the same host as
PostgreSQL. That's not required. **Only the database is shared** — Ollama
and the agent stay local to whichever machine runs them, which is what
keeps this private end-to-end even with a second, remote client. Nothing
below changes anything on the server.

### Already true on this server — nothing to do here

Verified already in place, so a client machine just needs to point at it:

| Condition | Value |
|---|---|
| `listen_addresses` | `*` (accepts non-localhost connections) |
| `pg_hba.conf` | `host all all 192.168.1.0/24 scram-sha-256` |
| Windows Firewall | inbound TCP 5432 allowed |
| Network profile | Private |
| Server LAN address | `192.168.1.69` |

If any of these ever need rebuilding, see `pipelines_dbt_postgresql/database.md`
("Server steps") — that project stood up the same server-side networking
this one now reuses.

### On the client (macOS, no WSL needed — Ollama and `wren` both run natively)

1. **Install Ollama** — [ollama.com/download](https://ollama.com/download), then pull the same models:

   ```bash
   ollama pull qwen3:8b
   ollama pull nomic-embed-text
   ```

   Apple Silicon runs these noticeably faster than this project's CPU-only
   Windows host (Metal acceleration) — no config needed, Ollama uses it
   automatically.

2. **Copy the project** over — everything except what's machine-specific.
   Bring: `README.md`, `requirements.txt`, `.env.example`, `agent/`,
   `scripts/`, `config/wren/` (including `target/mdl.json` and
   `.wren/memory/` if you'd rather not rebuild them — both are safe to skip
   and regenerate instead, see step 5). Leave behind: `.venv/`, `.env`,
   `config/wren/.env` — those hold this machine's Python environment and
   secrets and get recreated per-machine, not copied. A git remote is the
   cleanest way to do this repeatedly (same pattern as
   `pipelines_dbt_postgresql`'s client/server split); a one-time copy works
   too.

3. **Set up Python:**

   ```bash
   python3 -m venv .venv
   ./.venv/bin/pip install -r requirements.txt
   ```

4. **Create `.env`** (copy `.env.example`, fill in real values) — the only
   difference from the server's own `.env` is `POSTGRES_HOST`, which now
   points across the LAN instead of at `localhost`:

   ```ini
   OLLAMA_BASE_URL=http://localhost:11434   # this machine's own Ollama
   OLLAMA_CHAT_MODEL=qwen3:8b
   OLLAMA_EMBED_MODEL=nomic-embed-text

   POSTGRES_HOST=192.168.1.69               # the server's LAN address, not localhost
   POSTGRES_PORT=5432
   POSTGRES_DATABASE=analytics_lab
   POSTGRES_USER=gama
   POSTGRES_PASSWORD=...                    # ask for this out of band, don't commit it
   ```

   Copy the same file to `config/wren/.env` too —
   `WrenToolkit.from_project()` auto-loads `.env` from *inside* the wren
   project directory, not from the repo root.

5. **Register the connection profile and (re)build MDL** — `wren_project.yml`
   already pins `profile: datad`, so once a profile of that name exists
   locally it resolves automatically, no `--profile` flag needed anywhere:

   ```bash
   cd config/wren
   cat > /tmp/conn.yml <<'EOF'
   datasource: postgres
   host: ${POSTGRES_HOST}
   port: ${POSTGRES_PORT}
   database: ${POSTGRES_DATABASE}
   user: ${POSTGRES_USER}
   password: ${POSTGRES_PASSWORD}
   EOF
   wren profile add datad --from-file /tmp/conn.yml --activate

   wren context build            # skip if target/mdl.json was copied over
   wren memory index             # skip if .wren/memory/ was copied over
   ```

6. **Run it:**

   ```bash
   cd ../agent
   python main.py "your question"
   ```

Each client keeps its own independent `.wren/memory/` (local LanceDB files,
not shared over the network) — running `wren memory index` on one machine
never conflicts with another. Confirmed NL→SQL pairs saved via
`wren memory store` land in `knowledge/sql/` inside the project tree, so
they *do* travel with the project the next time you copy or `git pull` it.

## Telemetry — where to turn it off

WrenAI's telemetry (PostHog-based; anonymous usage stats that include asked questions, generated SQL, and connected-schema metadata — table/column names, not raw data) is **on by default**. Where to disable it depends on which build you're running:

| Build | Where the switch is |
|---|---|
| Launcher / Docker install ("Wren GenBI Classic") | Run the launcher with `--disable-telemetry` (e.g. `./wren-launcher-linux --disable-telemetry`), or set `TELEMETRY_ENABLED=false` in the deployment `.env`. Confirmed on-screen with a "telemetry disabled" message. |
| Current CLI (`wren` — what this project uses) | No dedicated telemetry doc page was found for this build at the time of writing. **Don't assume either way** — run `wren --help` / check the CLI reference for a telemetry flag or `TELEMETRY_*` env var, and set it explicitly in `.env` once confirmed. |

Treat this as a required setup step, not a default to trust. `.env.example` has a placeholder for whichever flag applies to your installed version.

## Dashboards & deployment

WrenAI's "Deploy" step builds a self-contained static dashboard app (`wren-core-wasm`) from a confirmed answer. **By default, the one-command flow ships that app to Vercel or Cloudflare Pages** for a shareable URL — that's an outbound hop, and the one part of this pipeline that isn't local unless you change it.

To keep dashboards on-host:

1. Build as usual: `wren skills get genbi` — but stop before the deploy-to-cloud step.
2. Serve the generated static output yourself: `scripts/serve_dashboard.sh` runs a plain local web server against the build in `dashboards/`.
3. Share the internal URL instead of a public Vercel/Cloudflare link.

## Hardware notes

For hosts without a dedicated GPU, with ≤16GB RAM, and HDD (not SSD) storage:

- Stick to **7-8B or smaller** quantized chat models (see `requirements.txt`). Larger models risk pushing the system into disk paging, which is especially costly on HDD storage — worse than the model size difference itself.
- Expect **CPU-only inference around 5-15 tokens/second** — summaries take seconds, not milliseconds.
- Keep model files and any WSL2 virtual disk on the fastest/internal drive; treat external or USB-attached storage as cold storage only.
- PostgreSQL competes with the model for RAM and disk cache — if queries feel slow, check whether it's the LLM or the database before assuming which one needs tuning.

## References

- WrenAI: https://github.com/Canner/WrenAI
- WrenAI docs: https://docs.getwren.ai/oss/introduction
- Ollama: https://ollama.com
