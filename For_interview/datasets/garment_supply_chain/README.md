# garment_supply_chain

Two public datasets stitched into one supply chain: a garment factory
upstream, an apparel distributor downstream.

**Full documentation — schema design, DDL, load steps, dbt models and SQL
exercises — is in [`../../garment_supply_chain_lab.md`](../../garment_supply_chain_lab.md).**
This file covers the data only.

## Layout

```
_source/                          upstream files, untouched
├── garments_worker_productivity.csv     UCI 597
└── DataCoSupplyChainDataset.csv         Mendeley (96 MB, git-ignored)

mfg/                              factory floor -> schema mfg_raw
├── production_log.csv                1,197 rows
└── team_product_line.csv                12 rows   ← AUTHORED, see below

dist/                             distributor -> schema dist_raw
├── categories.csv                        7 rows
├── products.csv                          8 rows
├── customers.csv                    13,785 rows
├── orders.csv                       35,190 rows
└── order_items.csv                  48,998 rows
```

## Sources

| | Upstream | Downstream |
|---|---|---|
| Dataset | Productivity Prediction of Garment Employees | DataCo Smart Supply Chain |
| Origin | UCI ML Repository #597 | Mendeley Data `10.17632/8gx2fvg2k6.5` |
| Licence | CC BY 4.0 | CC BY 4.0 |
| Grain | one row per team, per department, per day | one row per order line |
| Period | 2015-01-01 → 2015-03-11 | 2015-01-01 → 2018-01-31 |
| Scope here | all 1,197 rows | Apparel department only |

They overlap for **59 working days** in Q1 2015 — 2,262 orders, 3,236 order
lines — which is what makes the cross-schema exercises return real rows.

- Imran, A. A., Amin, M. N., Islam Bhuiyan, M. R., Rifat, M. R. I.
  *Productivity Prediction of Garment Employees*. UCI, 2020.
  <https://doi.org/10.24432/C51S6D>
- Constante, F., Silva, F., Pereira, A. *DataCo Smart Supply Chain for Big
  Data Analysis*. Mendeley Data V5, 2019.
  <https://doi.org/10.17632/8gx2fvg2k6.5>

## `team_product_line.csv` is authored

**Not source data.** The two datasets come from unrelated companies and share
no key, so no join between them exists in nature. This 12-row table maps each
factory team to a product category, using the **real** DataCo `category_id`
values — so the foreign key into `dist_raw.categories` is genuine even though
the team→category assignment is invented.

It is the conformed dimension that makes the cross-schema join possible. Say
so out loud if you present this work.

## Known source defects — deliberately preserved

The raw CSVs stay faithful to their sources. Cleaning happens in dbt staging,
which is the point of having a staging layer at all.

| Where | Defect |
|---|---|
| `production_log.department` | `sweing` — a misspelling of "sewing", in the source |
| `production_log.department` | `'finishing '` with a **trailing space** on 257 of 506 rows: a raw `GROUP BY` returns 3 groups for 2 departments |
| `production_log.quarter` | week-of-month, not calendar quarter — `Quarter5` exists |
| `production_log.wip` | NULL on all 506 finishing rows; WIP is a sewing concept, so the NULL is meaningful |
| `production_log.actual_productivity` | exceeds 1.0 (max 1.120) — teams beat target; do not clamp |
| `production_log.no_of_workers` | fractional (30.5) — teams split across lines |
| `production_log.day` | no Friday — the weekend in Bangladesh |
| `categories.category_name` | `'Baby '` with a trailing space |
| `categories` | `Cleats` and `Men's Footwear` are the two largest *Apparel* categories; `Total Gym 1400` is filed under `Cleats` |
| `orders.order_zipcode` | 86% empty; leading zeros already stripped upstream (`00603` → `603`) |

## Rebuilding

```bash
python3 prepare_datasets.py            # from cached _source/
python3 prepare_datasets.py --download # re-fetch both sources first (~96 MB)
```

Normalisation of the DataCo flat file into five tables is lossless: the
functional dependencies were verified first — 0 orders and 0 customers had
conflicting attributes across their rows, and there are no orphan foreign
keys in any direction.

Dropped during normalisation: `Customer Email` and `Customer Password`
(masked placeholders upstream), `Product Description` (empty on all 48,998
rows), `Order Profit Per Order` (byte-identical to `Benefit per order`).
