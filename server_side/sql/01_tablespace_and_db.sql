-- Run as the postgres superuser.
-- Creates a dedicated tablespace physically located inside this project
-- directory, and a single database for financial analytics.

CREATE TABLESPACE financial_tablespace
    LOCATION 'C:/Users/Gamaliel/Documents/GitHub/Financial_analytics/pgdata/financial_tablespace';

CREATE DATABASE findata
    WITH TABLESPACE = financial_tablespace
    ENCODING = 'UTF8';

COMMENT ON DATABASE findata IS 'Financial analytics data warehouse (single DB, multiple domain schemas)';
