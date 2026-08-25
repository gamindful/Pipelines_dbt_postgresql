"""
Load the CSV files produced by download_dataset.py (under datasets/) into
the crypto_fx schema of the findata Postgres database.

Upserts into crypto_fx.assets and crypto_fx.price_history, so it is safe to
re-run after downloading fresh data (existing rows for a date are updated,
not duplicated).

Connection settings are read from .env (PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD).

Usage:
    python utils/load_dataset.py
"""
import os
import sys
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

DATASETS_DIR = Path(__file__).parent.parent / "datasets"

# Same metadata as download_dataset.py's DEFAULT_SYMBOLS, keyed by the
# on-disk filename stem (matches how the downloader names CSVs).
SYMBOL_META = {
    "BTC-USD":  ("crypto", "BTC", "USD", "Bitcoin / US Dollar"),
    "ETH-USD":  ("crypto", "ETH", "USD", "Ethereum / US Dollar"),
    "SOL-USD":  ("crypto", "SOL", "USD", "Solana / US Dollar"),
    "EURUSD_X": ("fx",     "EUR", "USD", "Euro / US Dollar"),
    "GBPUSD_X": ("fx",     "GBP", "USD", "British Pound / US Dollar"),
    "USDJPY_X": ("fx",     "USD", "JPY", "US Dollar / Japanese Yen"),
}


def build_engine():
    load_dotenv(Path(__file__).parent.parent / ".env")
    required = ["PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"]
    missing = [v for v in required if not os.getenv(v)]
    if missing:
        sys.exit(f"Missing env vars in .env: {', '.join(missing)}")

    url = (
        f"postgresql+psycopg2://{os.getenv('PGUSER')}:{os.getenv('PGPASSWORD')}"
        f"@{os.getenv('PGHOST')}:{os.getenv('PGPORT')}/{os.getenv('PGDATABASE')}"
    )
    return create_engine(url)


def upsert_asset(conn, symbol, meta):
    asset_type, base_ccy, quote_ccy, display_name = meta
    row = conn.execute(
        text("""
            INSERT INTO crypto_fx.assets (symbol, asset_type, base_currency, quote_currency, display_name)
            VALUES (:symbol, :asset_type, :base_ccy, :quote_ccy, :display_name)
            ON CONFLICT (symbol) DO UPDATE
                SET display_name = EXCLUDED.display_name
            RETURNING asset_id
        """),
        {"symbol": symbol, "asset_type": asset_type, "base_ccy": base_ccy,
         "quote_ccy": quote_ccy, "display_name": display_name},
    ).first()
    return row[0]


def _to_native(value):
    """Convert numpy/pandas scalars (np.float64, NaN, NaT, ...) to plain
    Python types psycopg2 knows how to adapt; NaN/NaT become None."""
    if pd.isna(value):
        return None
    return value.item() if hasattr(value, "item") else value


def load_price_history(conn, asset_id, df):
    records = [
        {
            "asset_id": asset_id,
            "trade_date": idx.date(),
            "open": _to_native(row.get("Open")),
            "high": _to_native(row.get("High")),
            "low": _to_native(row.get("Low")),
            "close": _to_native(row.get("Close")),
            "adj_close": _to_native(row.get("Adj Close")),
            "volume": _to_native(row.get("Volume")),
        }
        for idx, row in df.iterrows()
    ]
    if not records:
        return 0

    conn.execute(
        text("""
            INSERT INTO crypto_fx.price_history
                (asset_id, trade_date, open, high, low, close, adj_close, volume)
            VALUES
                (:asset_id, :trade_date, :open, :high, :low, :close, :adj_close, :volume)
            ON CONFLICT (asset_id, trade_date) DO UPDATE
                SET open = EXCLUDED.open,
                    high = EXCLUDED.high,
                    low = EXCLUDED.low,
                    close = EXCLUDED.close,
                    adj_close = EXCLUDED.adj_close,
                    volume = EXCLUDED.volume,
                    loaded_at = now()
        """),
        records,
    )
    return len(records)


def main():
    if not DATASETS_DIR.exists():
        sys.exit(f"No datasets directory found at {DATASETS_DIR}. Run utils/download_dataset.py first.")

    engine = build_engine()
    csv_files = sorted(DATASETS_DIR.glob("*.csv"))
    if not csv_files:
        sys.exit(f"No CSV files found in {DATASETS_DIR}. Run utils/download_dataset.py first.")

    with engine.begin() as conn:
        for csv_path in csv_files:
            stem = csv_path.stem
            symbol = stem.replace("_X", "=X") if stem.endswith("_X") else stem
            meta = SYMBOL_META.get(stem, ("crypto", "?", "?", stem))

            df = pd.read_csv(csv_path, index_col="Date", parse_dates=["Date"])
            asset_id = upsert_asset(conn, symbol, meta)
            n = load_price_history(conn, asset_id, df)
            print(f"{symbol}: upserted {n} rows (asset_id={asset_id})")

    print("\nDone.")


if __name__ == "__main__":
    main()
