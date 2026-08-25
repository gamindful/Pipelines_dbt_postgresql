{{ config(materialized='table') }}

-- ref() points at the other model by NAME, not by schema.table.
-- dbt resolves it and builds stg_tables first, automatically.
select
    table_schema,
    count(*) as table_count,
    count(*) filter (where table_type = 'VIEW') as views,
    count(*) filter (where table_type = 'BASE TABLE') as tables
from {{ ref('stg_tables') }}
group by table_schema
order by table_count desc
