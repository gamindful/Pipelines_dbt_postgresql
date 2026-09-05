"""
Build the garment_supply_chain CSVs from their two upstream sources.

Sources (both CC BY 4.0, both re-downloadable by this script):

  UCI 597  Productivity Prediction of Garment Employees
           -> mfg/production_log.csv          1,197 rows, VERBATIM
  Mendeley DataCo Smart Supply Chain (DOI 10.17632/8gx2fvg2k6.5)
           -> dist/*.csv                      Apparel department only,
                                              normalised into 5 tables

Design rule, same as the credit_risk project: raw CSVs stay FAITHFUL to the
source. The known dirt ('sweing', 'finishing ' with a trailing space, empty
wip on finishing rows, Quarter5) is deliberately preserved -- cleaning it is
the staging layer's job, and it is the reason the staging models are worth
writing at all.

The one authored file is mfg/team_product_line.csv: a 12-row bridge mapping
factory teams to the product categories they supply. No such mapping exists
in either source -- the two datasets share no key. It is fabricated on
purpose so the cross-schema join has something honest to join ON, and it is
labelled as such everywhere it appears.

Usage:
    python3 prepare_datasets.py            # rebuild from cached _source/
    python3 prepare_datasets.py --download # re-fetch both sources first
"""
import argparse
import csv
import io
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).parent
SOURCE = HERE / "_source"
MFG = HERE / "mfg"
DIST = HERE / "dist"

UCI_URL = ("https://archive.ics.uci.edu/static/public/597/"
           "productivity+prediction+of+garment+employees.zip")
DATACO_URL = ("https://data.mendeley.com/public-files/datasets/8gx2fvg2k6/"
              "files/72784be5-36d3-44fe-b75d-0edbf1999f65/file_downloaded")

# 12 teams -> the category each supplies. AUTHORED, not source data.
TEAM_PRODUCT_LINE = [
    # team, category_id, category_name,        product_line
    # category_id values are the REAL DataCo ids (17, 18, 60, 63, 66, 70, 76),
    # so this table can carry a foreign key to dist_raw.categories.
    (1,  17, "Cleats",              "footwear"),
    (2,  18, "Men's Footwear",      "footwear"),
    (3,  17, "Cleats",              "footwear"),
    (4,  76, "Women's Clothing",    "apparel"),
    (5,  70, "Men's Clothing",      "apparel"),
    (6,  63, "Children's Clothing", "apparel"),
    (7,  76, "Women's Clothing",    "apparel"),
    (8,  18, "Men's Footwear",      "footwear"),
    (9,  60, "Baby ",               "apparel"),
    (10, 70, "Men's Clothing",      "apparel"),
    (11, 66, "Crafts",              "accessories"),
    (12, 63, "Children's Clothing", "apparel"),
]


def download():
    import requests
    SOURCE.mkdir(parents=True, exist_ok=True)

    print(f"downloading UCI 597 ...")
    z = requests.get(UCI_URL, timeout=120)
    z.raise_for_status()
    with zipfile.ZipFile(io.BytesIO(z.content)) as zf:
        name = next(n for n in zf.namelist() if n.endswith(".csv"))
        (SOURCE / "garments_worker_productivity.csv").write_bytes(zf.read(name))
    print(f"  -> _source/garments_worker_productivity.csv")

    print(f"downloading DataCo (~96 MB) ...")
    with requests.get(DATACO_URL, stream=True, timeout=600) as r:
        r.raise_for_status()
        with open(SOURCE / "DataCoSupplyChainDataset.csv", "wb") as fh:
            for chunk in r.iter_content(1 << 20):
                fh.write(chunk)
    print(f"  -> _source/DataCoSupplyChainDataset.csv")


def build_mfg():
    """Copy the UCI CSV through verbatim, adding only a surrogate key."""
    src = SOURCE / "garments_worker_productivity.csv"
    if not src.exists():
        sys.exit(f"missing {src} -- run with --download first")

    MFG.mkdir(parents=True, exist_ok=True)
    rows = list(csv.DictReader(open(src, encoding="utf-8")))

    out = MFG / "production_log.csv"
    with open(out, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["record_id", "date", "quarter", "department", "day", "team",
                    "targeted_productivity", "smv", "wip", "over_time",
                    "incentive", "idle_time", "idle_men", "no_of_style_change",
                    "no_of_workers", "actual_productivity"])
        for i, r in enumerate(rows, start=1):
            w.writerow([i] + [r[c] for c in (
                "date", "quarter", "department", "day", "team",
                "targeted_productivity", "smv", "wip", "over_time",
                "incentive", "idle_time", "idle_men", "no_of_style_change",
                "no_of_workers", "actual_productivity")])
    print(f"mfg/production_log.csv      {len(rows):>6,} rows")

    out = MFG / "team_product_line.csv"
    with open(out, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["team", "category_id", "category_name", "product_line"])
        w.writerows(TEAM_PRODUCT_LINE)
    print(f"mfg/team_product_line.csv   {len(TEAM_PRODUCT_LINE):>6,} rows  (AUTHORED)")


def build_dist():
    """Filter DataCo to the Apparel department, then split into 5 tables."""
    src = SOURCE / "DataCoSupplyChainDataset.csv"
    if not src.exists():
        sys.exit(f"missing {src} -- run with --download first")

    DIST.mkdir(parents=True, exist_ok=True)
    # latin-1: the file is not UTF-8, several customer names carry 0xf1 etc.
    rows = [r for r in csv.DictReader(open(src, encoding="latin-1"))
            if r["Department Name"].strip() == "Apparel"]

    def dump(name, header, records, key):
        seen, out = set(), []
        for r in records:
            k = key(r)
            if k in seen:
                continue
            seen.add(k)
            out.append(r)
        path = DIST / f"{name}.csv"
        with open(path, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow([h for h, _ in header])
            for r in out:
                w.writerow([f(r) for _, f in header])
        print(f"dist/{name}.csv{' ' * max(0, 18 - len(name))}{len(out):>6,} rows")

    # Customer Email / Customer Password are dropped: both are masked
    # placeholders upstream, and neither belongs in a portfolio database.
    dump("customers", [
        ("customer_id",      lambda r: r["Customer Id"]),
        ("first_name",       lambda r: r["Customer Fname"]),
        ("last_name",        lambda r: r["Customer Lname"]),
        ("segment",          lambda r: r["Customer Segment"]),
        ("city",             lambda r: r["Customer City"]),
        ("state",            lambda r: r["Customer State"]),
        ("country",          lambda r: r["Customer Country"]),
        ("zipcode",          lambda r: r["Customer Zipcode"]),
        ("street",           lambda r: r["Customer Street"]),
        ("latitude",         lambda r: r["Latitude"]),
        ("longitude",        lambda r: r["Longitude"]),
    ], rows, key=lambda r: r["Customer Id"])

    dump("categories", [
        ("category_id",      lambda r: r["Category Id"]),
        ("category_name",    lambda r: r["Category Name"]),
        ("department_id",    lambda r: r["Department Id"]),
        ("department_name",  lambda r: r["Department Name"]),
    ], rows, key=lambda r: r["Category Id"])

    # Product Description is empty on every row upstream -- dropped.
    dump("products", [
        ("product_card_id",  lambda r: r["Product Card Id"]),
        ("product_name",     lambda r: r["Product Name"]),
        ("category_id",      lambda r: r["Product Category Id"]),
        ("product_price",    lambda r: r["Product Price"]),
        ("product_status",   lambda r: r["Product Status"]),
    ], rows, key=lambda r: r["Product Card Id"])

    dump("orders", [
        ("order_id",             lambda r: r["Order Id"]),
        ("customer_id",          lambda r: r["Order Customer Id"]),
        ("order_date",           lambda r: r["order date (DateOrders)"]),
        ("shipping_date",        lambda r: r["shipping date (DateOrders)"]),
        ("order_status",         lambda r: r["Order Status"]),
        ("delivery_status",      lambda r: r["Delivery Status"]),
        ("late_delivery_risk",   lambda r: r["Late_delivery_risk"]),
        ("days_shipping_real",   lambda r: r["Days for shipping (real)"]),
        ("days_shipping_sched",  lambda r: r["Days for shipment (scheduled)"]),
        ("shipping_mode",        lambda r: r["Shipping Mode"]),
        ("order_type",           lambda r: r["Type"]),
        ("market",               lambda r: r["Market"]),
        ("order_region",         lambda r: r["Order Region"]),
        ("order_country",        lambda r: r["Order Country"]),
        ("order_state",          lambda r: r["Order State"]),
        ("order_city",           lambda r: r["Order City"]),
        ("order_zipcode",        lambda r: r["Order Zipcode"]),
    ], rows, key=lambda r: r["Order Id"])

    # Order Profit Per Order is byte-identical to Benefit per order on every
    # row -- only one is kept.
    dump("order_items", [
        ("order_item_id",        lambda r: r["Order Item Id"]),
        ("order_id",             lambda r: r["Order Id"]),
        ("product_card_id",      lambda r: r["Order Item Cardprod Id"]),
        ("quantity",             lambda r: r["Order Item Quantity"]),
        ("item_price",           lambda r: r["Order Item Product Price"]),
        ("discount",             lambda r: r["Order Item Discount"]),
        ("discount_rate",        lambda r: r["Order Item Discount Rate"]),
        ("sales",                lambda r: r["Sales"]),
        ("item_total",           lambda r: r["Order Item Total"]),
        ("profit_ratio",         lambda r: r["Order Item Profit Ratio"]),
        ("benefit_per_order",    lambda r: r["Benefit per order"]),
    ], rows, key=lambda r: r["Order Item Id"])


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--download", action="store_true",
                   help="re-fetch both sources into _source/ first")
    a = p.parse_args()
    if a.download:
        download()
    build_mfg()
    build_dist()
