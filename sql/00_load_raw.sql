/* ============================================================================
   00_load_raw.sql  -  Land the CSV extracts, untouched, into a raw schema
   ----------------------------------------------------------------------------
   Target  : PostgreSQL 14+ (run with psql from the repository root)
   Run     : psql -d northstar -f sql/00_load_raw.sql

   Everything lands as TEXT on purpose. Source systems send dates in two
   formats, currency symbols inside numbers and the odd "-1"; if we typed the
   columns here the load would fail on row 4,000 and tell us nothing useful.
   Land first, then clean and type in 01_schema_and_cleaning.sql.

   T-SQL equivalent: BULK INSERT / bcp into NVARCHAR staging tables.
   ========================================================================== */

DROP SCHEMA IF EXISTS raw CASCADE;
CREATE SCHEMA raw;

CREATE TABLE raw.dim_customers (
    account_id       TEXT,
    company_name     TEXT,
    industry         TEXT,
    region           TEXT,
    tier             TEXT,
    signup_date      TEXT,
    account_manager  TEXT
);

CREATE TABLE raw.fact_subscriptions (
    sub_id         TEXT,
    account_id     TEXT,
    billing_month  TEXT,
    mrr_gbp        TEXT,
    plan_type      TEXT,
    status         TEXT,
    churn_reason   TEXT
);

CREATE TABLE raw.fact_support_tickets (
    ticket_id    TEXT,
    account_id   TEXT,
    created_at   TEXT,
    resolved_at  TEXT,
    priority     TEXT,
    category     TEXT,
    csat_score   TEXT
);

CREATE TABLE raw.fact_product_usage (
    usage_id              TEXT,
    account_id            TEXT,
    activity_date         TEXT,
    active_users          TEXT,
    api_calls             TEXT,
    feature_adoption_pct  TEXT
);

\copy raw.dim_customers        FROM 'data/raw/dim_customers.csv'        WITH (FORMAT csv, HEADER true)
\copy raw.fact_subscriptions   FROM 'data/raw/fact_subscriptions.csv'   WITH (FORMAT csv, HEADER true)
\copy raw.fact_support_tickets FROM 'data/raw/fact_support_tickets.csv' WITH (FORMAT csv, HEADER true)
\copy raw.fact_product_usage   FROM 'data/raw/fact_product_usage.csv'   WITH (FORMAT csv, HEADER true)

-- Row counts as landed (compare against the generator's console output)
SELECT 'raw.dim_customers'        AS table_name, COUNT(*) AS rows_landed FROM raw.dim_customers
UNION ALL SELECT 'raw.fact_subscriptions',   COUNT(*) FROM raw.fact_subscriptions
UNION ALL SELECT 'raw.fact_support_tickets', COUNT(*) FROM raw.fact_support_tickets
UNION ALL SELECT 'raw.fact_product_usage',   COUNT(*) FROM raw.fact_product_usage;
