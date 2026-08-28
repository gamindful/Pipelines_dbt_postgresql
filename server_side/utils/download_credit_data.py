"""
Download the two UCI credit-risk datasets and normalise them to CSV under
datasets/.

Like download_dataset.py, this script only touches the filesystem -- it does
not talk to any database. Point load_credit_data.py at datasets/ afterwards.

Both sources need cleaning before they are usable:

  credit_default  .xls with TWO header rows; the real column names are on the
                  second row, the first is a merged title band.
  german_credit   .data with NO header at all, space-delimited, categorical
                  values coded as A11/A34/... (codebook: german.doc in the zip).

Usage:
    python utils/download_credit_data.py
    python utils/download_credit_data.py --only german_credit
    python utils/download_credit_data.py --keep-archives
"""
import argparse
import csv
import io
import sys
import zipfile
from pathlib import Path

import requests

DATASETS_DIR = Path(__file__).parent.parent / "datasets/credit"

SOURCES = {
    "credit_default": {
        "url": "https://archive.ics.uci.edu/static/public/350/default+of+credit+card+clients.zip",
        "member_suffix": ".xls",
        "licence": "CC BY 4.0",
    },
    "german_credit": {
        "url": "https://archive.ics.uci.edu/static/public/144/statlog+german+credit+data.zip",
        "member_suffix": "german.data",
        "licence": "CC BY 4.0",
    },
}

# Positional names from the UCI german.doc codebook. Verify against that file
# before relying on the semantics.
GERMAN_COLUMNS = [
    "checking_status", "duration_months", "credit_history", "purpose",
    "credit_amount", "savings_status", "employment_since", "installment_rate",
    "personal_status_sex", "other_debtors", "residence_since", "property_type",
    "age_years", "other_installment_plans", "housing", "existing_credits",
    "job", "dependents", "telephone", "foreign_worker", "credit_risk_class",
]

CREDIT_DEFAULT_COLUMNS = [
    "client_id", "limit_bal", "sex", "education", "marriage", "age",
    "pay_0", "pay_2", "pay_3", "pay_4", "pay_5", "pay_6",
    "bill_amt1", "bill_amt2", "bill_amt3", "bill_amt4", "bill_amt5", "bill_amt6",
    "pay_amt1", "pay_amt2", "pay_amt3", "pay_amt4", "pay_amt5", "pay_amt6",
    "default_next_month",
]


def fetch(name: str, spec: dict, keep: bool) -> Path:
    DATASETS_DIR.mkdir(parents=True, exist_ok=True)
    archive = DATASETS_DIR / f"{name}.zip"
    if archive.exists():
        print(f"  reusing cached {archive.name}")
    else:
        print(f"  downloading {spec['url']}")
        with requests.get(spec["url"], stream=True, timeout=180) as r:
            r.raise_for_status()
            with archive.open("wb") as fh:
                for chunk in r.iter_content(1 << 20):
                    fh.write(chunk)
        print(f"  saved {archive.name} ({archive.stat().st_size:,} bytes)")

    with zipfile.ZipFile(archive) as zf:
        members = [m for m in zf.namelist()
                   if m.lower().endswith(spec["member_suffix"].lower())]
        if not members:
            raise SystemExit(f"no member ending in {spec['member_suffix']!r}; "
                             f"archive holds {zf.namelist()}")
        member = members[0]
        payload = zf.read(member)
        print(f"  extracted {member} ({len(payload):,} bytes)")

    if not keep:
        archive.unlink()
    return payload


def normalise_credit_default(payload: bytes) -> list[list]:
    """.xls, two header rows -> rows of values, no header."""
    try:
        import xlrd
    except ImportError:
        raise SystemExit("credit_default needs xlrd:  pip install xlrd")
    book = xlrd.open_workbook(file_contents=payload)
    sheet = book.sheet_by_index(0)
    # Row 0 is a merged title band, row 1 holds the real names -> data starts at 2.
    return [sheet.row_values(r) for r in range(2, sheet.nrows)]


def normalise_german_credit(payload: bytes) -> list[list]:
    """.data, space-delimited, no header -> rows of values."""
    text = payload.decode("latin-1")
    rows = []
    for line in text.splitlines():
        parts = line.split()
        if parts:
            rows.append(parts)
    return rows


def _fmt(v) -> str:
    """xlrd reads every numeric .xls cell as a Python float, so integer-typed
    columns (client_id, sex, pay_0, ...) come out as '1.0', '2.0', etc. That
    fails to load into an INTEGER/SMALLINT column: '1.0'::smallint raises
    invalid input syntax. Collapse whole-number floats to plain int strings
    here so every downstream loader (COPY, psql \\copy, dbt seed) gets text
    Postgres's integer types actually accept. Monetary columns like
    limit_bal keep their fractional part when they have one.
    """
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def write_csv(name: str, header: list[str], rows: list[list]) -> Path:
    out = DATASETS_DIR / f"{name}.csv"
    with out.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        for row in rows:
            row = list(row)[: len(header)]
            row += [""] * (len(header) - len(row))
            w.writerow([_fmt(v) for v in row])
    print(f"  wrote {out.name}: {len(rows):,} rows x {len(header)} columns")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=sorted(SOURCES), help="fetch just one dataset")
    ap.add_argument("--keep-archives", action="store_true",
                    help="keep the downloaded .zip files")
    args = ap.parse_args()

    names = [args.only] if args.only else list(SOURCES)
    for name in names:
        print(f"\n=== {name} ({SOURCES[name]['licence']}) ===")
        payload = fetch(name, SOURCES[name], args.keep_archives)
        if name == "credit_default":
            write_csv(name, CREDIT_DEFAULT_COLUMNS, normalise_credit_default(payload))
        else:
            write_csv(name, GERMAN_COLUMNS, normalise_german_credit(payload))
    print("\nNext:  python utils/load_credit_data.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
