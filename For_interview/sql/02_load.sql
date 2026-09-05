-- Load the garment_lab CSVs.
-- Generated from For_interview/garment_supply_chain_lab.md, section 7.
--
-- \copy is client-side and the paths below are RELATIVE, so run psql from
-- the datasets directory:
--
--   cd For_interview/datasets/garment_supply_chain
--   psql -U app_garment -h 192.168.1.71 -d garment_lab -f ../../sql/02_load.sql
--
-- SET datestyle is not optional: the dates are month-first and ambiguous.

SET datestyle = 'ISO, MDY';

\copy mfg_raw.production_log (record_id, work_date, quarter, department, day_name, team, targeted_productivity, smv, wip, over_time, incentive, idle_time, idle_men, no_of_style_change, no_of_workers, actual_productivity) FROM 'mfg/production_log.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.categories (category_id, category_name, department_id, department_name) FROM 'dist/categories.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.products (product_card_id, product_name, category_id, product_price, product_status) FROM 'dist/products.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.customers (customer_id, first_name, last_name, segment, city, state, country, zipcode, street, latitude, longitude) FROM 'dist/customers.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.orders (order_id, customer_id, order_date, shipping_date, order_status, delivery_status, late_delivery_risk, days_shipping_real, days_shipping_sched, shipping_mode, order_type, market, order_region, order_country, order_state, order_city, order_zipcode) FROM 'dist/orders.csv' WITH (FORMAT csv, HEADER true)

\copy dist_raw.order_items (order_item_id, order_id, product_card_id, quantity, item_price, discount, discount_rate, sales, item_total, profit_ratio, benefit_per_order) FROM 'dist/order_items.csv' WITH (FORMAT csv, HEADER true)

-- Last: its category_id is a foreign key into dist_raw.categories.
\copy mfg_raw.team_product_line (team, category_id, category_name, product_line) FROM 'mfg/team_product_line.csv' WITH (FORMAT csv, HEADER true)
