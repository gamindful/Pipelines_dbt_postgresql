-- Proves the round trip: dbt reads the server's catalog and writes the
-- answer back to the server as a view in the public schema.
select
    table_schema,
    table_name,
    table_type
from information_schema.tables
where table_schema not in ('pg_catalog', 'information_schema')
