"""
Download the UCI datasets used by Projects 1-3 and normalise each to a clean
CSV under datasets/<domain>/.

Like download_dataset.py, this script only touches the filesystem -- it does
not talk to any database. Run load_uci.py afterwards.

Every one of these needs cleaning before it is usable, which is the point:

  credit_default        .xls, TWO header rows (row 0 is a merged title band)
  german_credit         .data, NO header, space-delimited, coded values
  bank_marketing        .csv inside a NESTED zip, semicolon-delimited
  polish_bankruptcy     .arff x5 (one per forecast horizon), '?' for missing
  taiwanese_bankruptcy  .csv, ~96 columns, leading spaces in header names

Usage:
    python utils/download_uci.py --list
    python utils/download_uci.py --dataset bank_marketing
    python utils/download_uci.py --all
"""
import argparse
import csv
import fnmatch
import io
import sys
import zipfile
from pathlib import Path

import requests

DATASETS_DIR = Path(__file__).parent.parent / "datasets"

# Positional names from the UCI german.doc codebook.
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

REGISTRY = {
    "credit_default": dict(
        project=1, domain="credit", uci=350,
        url="https://archive.ics.uci.edu/static/public/350/default+of+credit+card+clients.zip",
        member="*.xls", kind="xls", header_row=1, columns=CREDIT_DEFAULT_COLUMNS,
        title="Default of Credit Card Clients (Taiwan, 2005)"),

    "german_credit": dict(
        project=1, domain="credit", uci=144,
        url="https://archive.ics.uci.edu/static/public/144/statlog+german+credit+data.zip",
        member="german.data", kind="whitespace", columns=GERMAN_COLUMNS,
        title="Statlog German Credit"),

    "bank_marketing": dict(
        project=2, domain="bank_marketing", uci=222,
        url="https://archive.ics.uci.edu/static/public/222/bank+marketing.zip",
        member="bank-full.csv", kind="csv", delimiter=";", nested=True,
        rename={"default": "credit_default"},
        title="Bank Marketing (Portuguese retail bank)"),

    "polish_bankruptcy": dict(
        project=3, domain="bankruptcy", uci=365,
        url="https://archive.ics.uci.edu/static/public/365/polish+companies+bankruptcy+data.zip",
        member="*.arff", kind="arff", all_members=True, horizon_from_name=True,
        title="Polish Companies Bankruptcy"),

    "taiwanese_bankruptcy": dict(
        project=3, domain="bankruptcy", uci=572,
        url="https://archive.ics.uci.edu/static/public/572/taiwanese+bankruptcy+prediction.zip",
        member="*.csv", kind="csv", delimiter=",",
        title="Taiwanese Bankruptcy Prediction"),
}


# ------------------------------------------------------------------ fetch ---
def fetch_archive(key: str, spec: dict) -> bytes:
    out = DATASETS_DIR / spec["domain"]
    out.mkdir(parents=True, exist_ok=True)
    archive = out / f"{key}.zip"
    if archive.exists():
        print(f"  reusing cached {archive.name}")
        return archive.read_bytes()
    print(f"  downloading {spec['url']}")
    r = requests.get(spec["url"], timeout=300)
    r.raise_for_status()
    archive.write_bytes(r.content)
    print(f"  saved {archive.name} ({len(r.content):,} bytes)")
    return r.content


def members(payload: bytes, pattern: str, nested: bool) -> list[tuple[str, bytes]]:
    """Return [(name, bytes)] matching pattern, descending into a nested zip."""
    found = []
    with zipfile.ZipFile(io.BytesIO(payload)) as zf:
        for n in zf.namelist():
            if fnmatch.fnmatch(Path(n).name, pattern):
                found.append((n, zf.read(n)))
        if not found and nested:
            for n in zf.namelist():
                if n.lower().endswith(".zip"):
                    found += members(zf.read(n), pattern, False)
    if not found:
        raise SystemExit(f"no member matching {pattern!r} in the archive")
    return sorted(found)


# ----------------------------------------------------------------- parsers ---
def parse_xls(blob: bytes, spec: dict):
    try:
        import xlrd
    except ImportError:
        raise SystemExit("this dataset needs xlrd:  pip install xlrd")
    sheet = xlrd.open_workbook(file_contents=blob).sheet_by_index(0)
    start = int(spec.get("header_row", 0)) + 1
    return spec["columns"], [sheet.row_values(r) for r in range(start, sheet.nrows)]


def parse_whitespace(blob: bytes, spec: dict):
    rows = [ln.split() for ln in blob.decode("latin-1").splitlines() if ln.strip()]
    return spec["columns"], rows


def parse_csv(blob: bytes, spec: dict):
    text = blob.decode("latin-1")
    reader = csv.reader(io.StringIO(text), delimiter=spec.get("delimiter", ","))
    rows = [r for r in reader if any(c.strip() for c in r)]
    header = [h.strip().strip('"').lower().replace(" ", "_") for h in rows[0]]
    header = [spec.get("rename", {}).get(h, h) for h in header]
    return header, rows[1:]


def parse_arff(blob: bytes, spec: dict):
    header, rows, in_data = [], [], False
    for line in blob.decode("latin-1").splitlines():
        s = line.strip()
        if not s or s.startswith("%"):
            continue
        low = s.lower()
        if low.startswith("@attribute"):
            header.append(s.split()[1].strip("'\"").lower())
        elif low.startswith("@data"):
            in_data = True
        elif in_data:
            rows.append([None if v.strip() == "?" else v.strip()
                         for v in next(csv.reader([s]))])
    return header, rows


PARSERS = {"xls": parse_xls, "whitespace": parse_whitespace,
           "csv": parse_csv, "arff": parse_arff}


# ------------------------------------------------------------------ write ---
def write_csv(key: str, spec: dict, header: list, rows: list) -> Path:
    out = DATASETS_DIR / spec["domain"] / f"{key}.csv"
    with out.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        for row in rows:
            row = list(row)[: len(header)]
            row += [""] * (len(header) - len(row))
            w.writerow(["" if v is None else str(v).strip() for v in row])
    print(f"  wrote {out.relative_to(DATASETS_DIR.parent)}: "
          f"{len(rows):,} rows x {len(header)} columns")
    return out


def download(key: str) -> None:
    spec = REGISTRY[key]
    print(f"\n=== {key} — {spec['title']} (UCI {spec['uci']}, CC BY 4.0) ===")
    payload = fetch_archive(key, spec)
    parts = members(payload, spec["member"], spec.get("nested", False))
    if not spec.get("all_members"):
        parts = parts[:1]

    header, rows = None, []
    for name, blob in parts:
        h, r = PARSERS[spec["kind"]](blob, spec)
        if spec.get("horizon_from_name"):
            # 1year.arff .. 5year.arff -> keep which horizon each row came from
            digits = "".join(c for c in Path(name).stem if c.isdigit())
            h = h + ["forecast_horizon_years"]
            r = [row + [digits or None] for row in r]
        header = header or h
        rows += r
        if len(parts) > 1:
            print(f"    {Path(name).name}: {len(r):,} rows")
    write_csv(key, spec, header, rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", choices=sorted(REGISTRY))
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    if a.list or not (a.dataset or a.all):
        print(f"{'KEY':<24} {'PRJ':<4} {'DOMAIN':<16} TITLE")
        for k, v in sorted(REGISTRY.items(), key=lambda kv: kv[1]["project"]):
            print(f"{k:<24} {v['project']:<4} {v['domain']:<16} {v['title']}")
        return 0

    for k in (sorted(REGISTRY) if a.all else [a.dataset]):
        download(k)
    print("\nNext:  python utils/load_uci.py --all")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
