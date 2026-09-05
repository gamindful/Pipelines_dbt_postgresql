-- Ad-hoc query against findata. Run with psql, not dbt:
--   psql -h 192.168.1.71 -U postgres -d findata -f projects/crypto_analysis/assets.sql
--select *
--from crypto_fx.assets
select a.symbol, p.trade_date, p.close, p.volume from crypto_fx.price_history p join crypto_fx.assets a using (asset_id) order by p.trade_date desc limit 20;