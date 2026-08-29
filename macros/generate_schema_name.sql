{#
    dbt's default generate_schema_name concatenates the profile's target
    schema with a model's custom +schema config (e.g. profile schema
    'staging' + model config 'marts' -> 'staging_marts'). This project's
    design (database.md, README.md) calls for the custom schema to be used
    exactly as given -- 'staging', 'intermediate', 'marts' -- so override the
    default concatenation behavior.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
