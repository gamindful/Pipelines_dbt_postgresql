"""
Download daily OHLCV history for a set of crypto and FX pairs via yfinance
and save one CSV per symbol under datasets/.

This script only touches the filesystem -- it does not talk to any
database. Point a separate loader at the datasets/ folder if you need the
data in Postgres or elsewhere.

Usage:
    python utils/download_dataset.py
    python utils/download_dataset.py --period 5y
    python utils/download_dataset.py --symbols BTC-USD,ETH-USD,EURUSD=X
"""
import argparse
import sys
from pathlib import Path

import yfinance as yf

DATASETS_DIR = Path(__file__).parent.parent / "datasets"

# symbol -> (asset_type, base_currency, quote_currency, display_name)
DEFAULT_SYMBOLS = {
    "BTC-USD":  ("crypto", "BTC", "USD", "Bitcoin / US Dollar"),
    "ETH-USD":  ("crypto", "ETH", "USD", "Ethereum / US Dollar"),
    "SOL-USD":  ("crypto", "SOL", "USD", "Solana / US Dollar"),
    "EURUSD=X": ("fx",     "EUR", "USD", "Euro / US Dollar"),
    "GBPUSD=X": ("fx",     "GBP", "USD", "British Pound / US Dollar"),
    "USDJPY=X": ("fx",     "USD", "JPY", "US Dollar / Japanese Yen"),
}


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--period", default="2y",
                   help="yfinance period, e.g. 1y, 2y, 5y, max (default: 2y)")
    p.add_argument("--interval", default="1d",
                   help="yfinance interval, e.g. 1d, 1h (default: 1d)")
    p.add_argument("--symbols", default=None,
                   help="comma-separated ticker list; defaults to the built-in crypto+FX set")
    return p.parse_args()


def main():
    args = parse_args()
    symbols = args.symbols.split(",") if args.symbols else list(DEFAULT_SYMBOLS.keys())

    DATASETS_DIR.mkdir(parents=True, exist_ok=True)

    failures = []
    for symbol in symbols:
        print(f"Downloading {symbol} ({args.period}, {args.interval}) ...")
        try:
            df = yf.download(
                symbol,
                period=args.period,
                interval=args.interval,
                auto_adjust=False,
                progress=False,
            )
        except Exception as exc:  # noqa: BLE001 - report and continue with other symbols
            print(f"  FAILED: {exc}", file=sys.stderr)
            failures.append(symbol)
            continue

        if df.empty:
            print(f"  WARNING: no data returned for {symbol}", file=sys.stderr)
            failures.append(symbol)
            continue

        # yfinance can return MultiIndex columns for a single symbol in
        # recent versions; flatten them so the CSV header is plain.
        if isinstance(df.columns, __import__("pandas").MultiIndex):
            df.columns = df.columns.get_level_values(0)

        df.index.name = "Date"
        out_path = DATASETS_DIR / f"{symbol.replace('=', '_')}.csv"
        df.to_csv(out_path)
        print(f"  saved {len(df)} rows -> {out_path.relative_to(Path(__file__).parent.parent)}")

    if failures:
        print(f"\nCompleted with {len(failures)} failure(s): {', '.join(failures)}", file=sys.stderr)
        sys.exit(1)

    print("\nDone.")


if __name__ == "__main__":
    main()
