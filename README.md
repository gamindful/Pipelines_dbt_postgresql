# Pipelines_dbt_postgresql

dbt models targeting PostgreSQL 18.6 on a LAN server.

## Setup

    python3 -m venv venv
    ./venv/bin/pip install -r requirements.txt

Copy the profile block from `profiles.example.yml` into `~/.dbt/profiles.yml`
and fill in your own host and credentials. dbt reads it from there, not from
this repo -- which is why no credential is committed.

## Use

    ./venv/bin/dbt debug     # verify the connection
    ./venv/bin/dbt run       # build models
    ./venv/bin/dbt test      # validate them
