-- ============================================================
-- Where am I? (cluster + database + schema + user)
-- ============================================================
select current_database()      as database,
       current_user           as connected_as,
       current_schema()       as default_schema,
       inet_server_addr()     as server,
       version()              as server_version;

-- ============================================================
-- CLUSTER level -- every database on 192.168.1.69
-- ============================================================
select datname                                        as database,
       pg_get_userbyid(datdba)                        as owner,
       pg_size_pretty(pg_database_size(datname))      as size
  from pg_database
 where not datistemplate
 order by pg_database_size(datname) desc;

-- ============================================================
-- DATABASE level -- schemas inside the one I'm connected to
-- ============================================================
select nspname                        as schema,
       pg_get_userbyid(nspowner)      as owner
  from pg_namespace
 where nspname not in ('pg_catalog','information_schema','pg_toast')
 order by 1;

-- ============================================================
-- SCHEMA level -- tables and views
-- ============================================================
select table_schema, table_name, table_type
  from information_schema.tables
 where table_schema not in ('pg_catalog','information_schema')
 order by 1, 2;

-- ============================================================
-- OBJECT level -- columns of one table
-- ============================================================
select column_name, data_type, is_nullable, column_default
  from information_schema.columns
 where table_schema = 'crypto_fx'
   and table_name   = 'assets'
 order by ordinal_position;

-- ============================================================
-- Sizes and approximate row counts
-- ============================================================
select schemaname                                        as schema,
       relname                                           as table,
       n_live_tup                                        as approx_rows,
       pg_size_pretty(pg_total_relation_size(relid))     as size
  from pg_stat_user_tables
 order by pg_total_relation_size(relid) desc;

-- ============================================================
-- Roles are CLUSTER level; privileges are per schema/table
-- ============================================================
select rolname, rolsuper, rolcanlogin, rolcreatedb
  from pg_roles
 where rolcanlogin
 order by 1;

select grantee, table_schema, table_name,
       string_agg(privilege_type, ', ' order by privilege_type) as privileges
  from information_schema.role_table_grants
 where table_schema not in ('pg_catalog','information_schema')
 group by 1, 2, 3
 order by 1, 2, 3;

-- ============================================================
-- Who is connected right now
-- ============================================================
select pid, usename, datname, state,
       now() - state_change as in_state,
       left(query, 60)      as query
  from pg_stat_activity
 where pid <> pg_backend_pid()
 order by state_change desc;

-- ============================================================
-- Your actual data -- one row per instrument
-- ============================================================
select a.symbol,
       a.asset_type,
       count(*)                 as bars,
       min(p.trade_date)        as first_day,
       max(p.trade_date)        as last_day,
       round(avg(p.close), 4)   as avg_close,
       max(p.loaded_at)         as last_loaded
  from crypto_fx.price_history p
  join crypto_fx.assets a using (asset_id)
 group by 1, 2
 order by 1;
