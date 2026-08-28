"""
Load the CSVs produced by download_uci.py into the analytics_lab database.

Connection settings come from server_side/.env
(PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD), same as load_dataset.py.

Two loading strategies, chosen per dataset:

  declared   the table already exists with typed columns, CHECK constraints
             and DEFAULTs (see sql/03..06). The frame is appended into it, so
             the database enforces the contract. Serial keys, `source` and
             `loaded_at` fill themselves from their DEFAULTs.

  inferred   the table is created from the file's own header. Used for the
             two bankruptcy sets, where hand-writing ~160 ratio column names
             nobody has read is how silent mismatches happen.

Every load is idempotent: declared targets are TRUNCATEd first, inferred
targets are replaced.

Usage:
    python utils/load_uci.py --list
    python utils/load_uci.py --dataset bank_marketing
    python utils/load_uci.py --all
"""
import argparse
import os
import sys
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

ROOT = Path(__file__).parent.parent
DATASETS_DIR = ROOT / "datasets"

TARGETS = {
    "credit_default": dict(
        domain="credit", schema="credit_risk", table="credit_default",
        strategy="declared"),
    "german_credit": dict(
        domain="credit", schema="credit_risk", table="german_credit",
        strategy="declared"),
    "bank_marketing": dict(
        domain="bank_marketing", schema="bank_marketing", table="campaign_contacts",
        strategy="declared"),
    "polish_bankruptcy": dict(
        domain="bankruptcy", schema="bankruptcy", table="polish_bankruptcy",
        strategy="inferred"),
    "taiwanese_bankruptcy": dict(
        domain="bankruptcy", schema="bankruptcy", table="taiwanese_bankruptcy",
        strategy="inferred"),
}


def engine_from_env():
    load_dotenv(ROOT / ".env")
    user = os.getenv("PGUSER", "gama")
    pwd  = os.getenv("PGPASSWORD", "")
    host = os.getenv("PGHOST", "localhost")
    port = os.getenv("PGPORT", "5432")
    db   = os.getenv("PGDATABASE", "analytics_lab")
    print(f"target: {user}@{host}:{port}/{db}")
    return create_engine(f"postgresql+psycopg2://{user}:{pwd}@{host}:{port}/{db}")


def load_one(eng, key: str, spec: dict) -> None:
    path = DATASETS_DIR / spec["domain"] / f"{key}.csv"
    if not path.exists():
        raise SystemExit(f"{path} not found -- run download_uci.py --dataset {key}")

    df = pd.read_csv(path)
    # Postgres folds unquoted identifiers to lower case; match that, and strip
    # the stray leading spaces the Taiwanese file has in its header.
    df.columns = [c.strip().lower().replace(" ", "_").replace("?", "")
                  for c in df.columns]

    schema, table = spec["schema"], spec["table"]
    print(f"\n=== {key} -> {schema}.{table}  ({spec['strategy']}) ===")
    print(f"  {len(df):,} rows x {len(df.columns)} columns from {path.name}")

    if spec["strategy"] == "declared":
        with eng.begin() as cx:
            cx.execute(text(f'TRUNCATE {schema}.{table} RESTART IDENTITY CASCADE'))
        df.to_sql(table, eng, schema=schema, if_exists="append", index=False,
                  method="multi", chunksize=5000)
    else:
        df.to_sql(table, eng, schema=schema, if_exists="replace", index=False,
                  method="multi", chunksize=5000)
        # to_sql cannot add these, and dbt source freshness needs loaded_at.
        with eng.begin() as cx:
            cx.execute(text(
                f'ALTER TABLE {schema}.{table} '
                f'ADD COLUMN IF NOT EXISTS loaded_at timestamptz NOT NULL DEFAULT now()'))
            cx.execute(text(
                f'ALTER TABLE {schema}.{table} '
                f"ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'uci'"))

    with eng.connect() as cx:
        n = cx.execute(text(f'SELECT count(*) FROM {schema}.{table}')).scalar()
    print(f"  {n:,} rows now in {schema}.{table}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", choices=sorted(TARGETS))
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    if a.list or not (a.dataset or a.all):
        print(f"{'KEY':<24} {'TARGET':<40} STRATEGY")
        for k, v in TARGETS.items():
            print(f"{k:<24} {v['schema'] + '.' + v['table']:<40} {v['strategy']}")
        return 0

    eng = engine_from_env()
    for k in (list(TARGETS) if a.all else [a.dataset]):
        load_one(eng, k, TARGETS[k])
    print("\nNext, from the client:  dbt build")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
