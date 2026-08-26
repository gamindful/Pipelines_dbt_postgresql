"""
Load datasets/credit_default.csv and datasets/german_credit.csv into the
credit_raw schema of the credit_risk database.

Connection settings come from server_side/.env (PGHOST, PGPORT, PGDATABASE,
PGUSER, PGPASSWORD) or from the environment, so no credential is hardcoded.
Run this on the SERVER for a localhost load, or from the client by pointing
PGHOST at 192.168.1.69 -- the code is identical either way.

Bulk loading uses client-side COPY ... FROM STDIN rather than server-side
COPY '<path>'. Server-side COPY reads the SERVER's filesystem, which would
hardcode a Windows path into this repo and require the postgres service
account to have read access. STDIN streams over the existing connection and
behaves the same from macOS, Windows or Linux.

Usage:
    python utils/load_credit_data.py
    python utils/load_credit_data.py --only german_credit
    python utils/load_credit_data.py --truncate
"""
import argparse
import os
import sys
from pathlib import Path

import psycopg2
from psycopg2 import sql

ROOT = Path(__file__).parent.parent
DATASETS_DIR = ROOT / "datasets"
ENV_FILE = ROOT / ".env"

TARGETS = {
    "credit_default": ("credit_raw", "credit_default", [
        "client_id", "limit_bal", "sex", "education", "marriage", "age",
        "pay_0", "pay_2", "pay_3", "pay_4", "pay_5", "pay_6",
        "bill_amt1", "bill_amt2", "bill_amt3", "bill_amt4", "bill_amt5", "bill_amt6",
        "pay_amt1", "pay_amt2", "pay_amt3", "pay_amt4", "pay_amt5", "pay_amt6",
        "default_next_month",
    ]),
    "german_credit": ("credit_raw", "german_credit", [
        "checking_status", "duration_months", "credit_history", "purpose",
        "credit_amount", "savings_status", "employment_since", "installment_rate",
        "personal_status_sex", "other_debtors", "residence_since", "property_type",
        "age_years", "other_installment_plans", "housing", "existing_credits",
        "job", "dependents", "telephone", "foreign_worker", "credit_risk_class",
    ]),
}


def load_env() -> dict:
    """Read .env if present; real environment variables win."""
    cfg = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    for k in ("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"):
        if os.environ.get(k):
            cfg[k] = os.environ[k]
    return cfg


def connect(cfg: dict):
    try:
        return psycopg2.connect(
            host=cfg.get("PGHOST", "localhost"),
            port=int(cfg.get("PGPORT", 5432)),
            dbname=cfg.get("PGDATABASE", "credit_risk"),
            user=cfg.get("PGUSER", "app_credit"),
            password=cfg.get("PGPASSWORD", ""),
            connect_timeout=10,
        )
    except UnicodeDecodeError as exc:
        # Spanish-locale servers emit WIN1252 guillemets that psycopg2 cannot
        # decode as UTF-8, hiding the real message. Recover it.
        raise SystemExit("server error: "
                         + exc.object.decode("latin-1", "replace").strip())


def load_one(conn, name: str, truncate: bool) -> None:
    schema, table, cols = TARGETS[name]
    path = DATASETS_DIR / f"{name}.csv"
    if not path.exists():
        raise SystemExit(f"{path} not found -- run download_credit_data.py first")

    ident = sql.Identifier(schema, table)
    print(f"\n=== {name} -> {schema}.{table} ===")

    with conn, conn.cursor() as cur:
        if truncate:
            cur.execute(sql.SQL("TRUNCATE {} RESTART IDENTITY").format(ident))
            print("  truncated")

        copy_stmt = sql.SQL("COPY {} ({}) FROM STDIN WITH (FORMAT csv, HEADER true)").format(
            ident, sql.SQL(", ").join(sql.Identifier(c) for c in cols)
        )
        with path.open("r", encoding="utf-8") as fh:
            cur.copy_expert(copy_stmt.as_string(cur), fh)

        cur.execute(sql.SQL("SELECT count(*) FROM {}").format(ident))
        print(f"  {cur.fetchone()[0]:,} rows now in {schema}.{table}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=sorted(TARGETS))
    ap.add_argument("--truncate", action="store_true",
                    help="empty the table before loading (makes reruns idempotent)")
    args = ap.parse_args()

    cfg = load_env()
    print(f"target: {cfg.get('PGUSER')}@{cfg.get('PGHOST')}:"
          f"{cfg.get('PGPORT', 5432)}/{cfg.get('PGDATABASE')}")

    conn = connect(cfg)
    try:
        for name in ([args.only] if args.only else list(TARGETS)):
            load_one(conn, name, args.truncate)
    finally:
        conn.close()
    print("\nNext, from the client:")
    print("  dbt run  --profile credit_risk --select credit_risk_marts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
