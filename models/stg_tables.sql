-- A dbt model is just a SELECT. dbt wraps it in `create view as ...`
-- and gets the connection from the profile named in dbt_project.yml.
select
    table_schema,
    table_name,
    table_type
from information_schema.tables
where table_schema not in ('pg_catalog', 'information_schema')
