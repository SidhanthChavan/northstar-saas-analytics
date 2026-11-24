/* ============================================================================
   01_schema_and_cleaning.sql  -  Typed, de-duplicated core tables
   ----------------------------------------------------------------------------
   Target  : PostgreSQL 14+
   Run     : psql -d northstar -f sql/01_schema_and_cleaning.sql
   Reads   : raw.*      (from 00_load_raw.sql)
   Writes  : core.*     (clean tables with PKs / FKs, the single source of truth)

   What gets fixed here, and why it matters for the numbers downstream:

   dim_customers
     - duplicate CRM records       -> keep the most complete row per account
     - internal test accounts      -> excluded (they would inflate logo counts)
     - casing / stray whitespace   -> conformed tier, region and industry values
     - mixed date formats          -> ISO and UK DD/MM/YYYY both parsed
     - missing signup dates        -> imputed from first billing month, flagged
   fact_subscriptions
     - billing re-sync duplicates  -> one row per account per month
     - "£1,234.00" style text      -> numeric
     - missing MRR on active rows  -> carried forward from the prior month
     - churn reasons               -> mapped to a fixed list; blanks = 'Not recorded'
     - orphan rows (test accounts) -> dropped by the FK filter
   fact_support_tickets
     - duplicate webhook events    -> keep the latest state of each ticket
     - 'critical' / 'P1' / 'Critical ' -> one priority code
     - resolved before created     -> resolution time nulled, row flagged
     - CSAT outside 1-5            -> null
     - SLA outcome                 -> calculated once here, not in every report
   fact_product_usage
     - duplicate weekly snapshots  -> one row per account per week
     - negative API counts         -> null (known collector bug)
     - adoption sent as 0-1        -> rescaled to 0-100

   T-SQL notes: REGEXP_REPLACE -> TRANSLATE/REPLACE or a CLR function;
   TO_DATE(x,'DD/MM/YYYY') -> TRY_CONVERT(date, x, 103);  ::numeric -> TRY_CAST.
   ========================================================================== */

DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA core;

/* ----------------------------------------------------------------------------
   0. Reference tables
   ------------------------------------------------------------------------- */

-- When the extract was taken. Open tickets are judged against this moment.
CREATE TABLE core.etl_config (
    snapshot_ts        TIMESTAMP NOT NULL,
    history_start      DATE      NOT NULL,
    last_full_month    DATE      NOT NULL
);
INSERT INTO core.etl_config VALUES ('2026-09-30 23:59:59', '2023-10-01', '2026-09-01');

-- Contracted resolution SLAs (calendar hours, 24x7 support model)
CREATE TABLE core.ref_sla_policy (
    priority_code   CHAR(2)      PRIMARY KEY,
    priority_label  VARCHAR(20)  NOT NULL,
    sla_hours       INT          NOT NULL,
    is_high_priority BOOLEAN     NOT NULL
);
INSERT INTO core.ref_sla_policy VALUES
    ('P1', 'P1 - Critical',   8, TRUE),
    ('P2', 'P2 - High',      24, TRUE),
    ('P3', 'P3 - Medium',    72, FALSE),
    ('P4', 'P4 - Low',      120, FALSE);

CREATE TABLE core.ref_churn_reason (
    churn_reason        VARCHAR(40) PRIMARY KEY,
    reason_group        VARCHAR(20) NOT NULL   -- what we could have influenced
);
INSERT INTO core.ref_churn_reason VALUES
    ('Poor support experience',     'Controllable'),
    ('Low product adoption',        'Controllable'),
    ('Price / budget cuts',         'Commercial'),
    ('Moved to competitor',         'Commercial'),
    ('Consolidated tooling',        'Commercial'),
    ('Business closed / acquired',  'Uncontrollable'),
    ('Not recorded',                'Unknown');

CREATE TABLE core.ref_ticket_category (
    category_key  VARCHAR(30) PRIMARY KEY,   -- normalised lower-case spelling
    category      VARCHAR(30) NOT NULL,
    owning_team   VARCHAR(30) NOT NULL
);
INSERT INTO core.ref_ticket_category VALUES
    ('integration / api', 'Integration / API', 'Engineering escalation'),
    ('performance',       'Performance',       'Engineering escalation'),
    ('bug',               'Bug',               'Engineering escalation'),
    ('data import',       'Data Import',       'Support tier 2'),
    ('feature request',   'Feature Request',   'Product'),
    ('billing',           'Billing',           'Support tier 1'),
    ('access & sso',      'Access & SSO',      'Support tier 1'),
    ('onboarding',        'Onboarding',        'Customer success');


/* ----------------------------------------------------------------------------
   1. dim_customers
   ------------------------------------------------------------------------- */
CREATE TABLE core.dim_customers (
    account_id            VARCHAR(12)  PRIMARY KEY,
    company_name          VARCHAR(120) NOT NULL,
    industry              VARCHAR(40)  NOT NULL,
    region                VARCHAR(40)  NOT NULL,
    tier                  VARCHAR(12)  NOT NULL
                          CHECK (tier IN ('SMB', 'Mid-Market', 'Enterprise')),
    signup_date           DATE,
    signup_date_imputed   BOOLEAN      NOT NULL DEFAULT FALSE,
    account_manager       VARCHAR(60)  NOT NULL
);

INSERT INTO core.dim_customers
    (account_id, company_name, industry, region, tier, signup_date, account_manager)
WITH standardised AS (
    SELECT
        UPPER(TRIM(account_id))                                        AS account_id,
        REGEXP_REPLACE(TRIM(company_name), '\s+', ' ', 'g')            AS company_name,
        NULLIF(INITCAP(TRIM(industry)), '')                            AS industry,
        NULLIF(INITCAP(TRIM(region)), '')                              AS region,
        CASE LOWER(TRIM(tier))
             WHEN 'smb'         THEN 'SMB'
             WHEN 'mid-market'  THEN 'Mid-Market'
             WHEN 'enterprise'  THEN 'Enterprise'
        END                                                            AS tier,
        CASE
             WHEN TRIM(signup_date) ~ '^\d{4}-\d{2}-\d{2}$'
                  THEN TO_DATE(TRIM(signup_date), 'YYYY-MM-DD')
             WHEN TRIM(signup_date) ~ '^\d{2}/\d{2}/\d{4}$'
                  THEN TO_DATE(TRIM(signup_date), 'DD/MM/YYYY')        -- UK format
        END                                                            AS signup_date,
        NULLIF(TRIM(account_manager), '')                              AS account_manager
    FROM raw.dim_customers
    WHERE company_name NOT ILIKE 'TEST ACCOUNT%'                       -- internal QA records
      AND COALESCE(account_manager, '') <> 'Internal QA'
),
ranked AS (
    SELECT s.*,
           ROW_NUMBER() OVER (
               PARTITION BY account_id
               ORDER BY (industry IS NOT NULL)::INT
                      + (account_manager IS NOT NULL)::INT
                      + (signup_date IS NOT NULL)::INT DESC,           -- most complete first
                        company_name
           ) AS rn
    FROM standardised s
)
SELECT account_id,
       company_name,
       COALESCE(industry, 'Unknown'),
       COALESCE(region, 'Unknown'),
       tier,
       signup_date,
       COALESCE(account_manager, 'Unassigned')
FROM ranked
WHERE rn = 1;


/* ----------------------------------------------------------------------------
   2. fact_subscriptions  (grain: one account, one billing month)
   ------------------------------------------------------------------------- */
CREATE TABLE core.fact_subscriptions (
    sub_id          VARCHAR(16)   PRIMARY KEY,
    account_id      VARCHAR(12)   NOT NULL REFERENCES core.dim_customers (account_id),
    billing_month   DATE          NOT NULL CHECK (EXTRACT(DAY FROM billing_month) = 1),
    mrr_gbp         NUMERIC(12,2) NOT NULL CHECK (mrr_gbp >= 0),
    mrr_imputed     BOOLEAN       NOT NULL DEFAULT FALSE,
    plan_type       VARCHAR(10)   NOT NULL CHECK (plan_type IN ('Annual', 'Monthly')),
    status          VARCHAR(10)   NOT NULL CHECK (status IN ('Active', 'Churned')),
    churn_reason    VARCHAR(40)   REFERENCES core.ref_churn_reason (churn_reason),
    CONSTRAINT uq_sub_account_month UNIQUE (account_id, billing_month),
    CONSTRAINT ck_churn_reason CHECK (
        (status = 'Churned' AND churn_reason IS NOT NULL) OR
        (status = 'Active'  AND churn_reason IS NULL))
);

INSERT INTO core.fact_subscriptions
WITH standardised AS (
    SELECT
        TRIM(sub_id)                                                   AS sub_id,
        UPPER(TRIM(account_id))                                        AS account_id,
        DATE_TRUNC('month', TRIM(billing_month)::DATE)::DATE           AS billing_month,
        NULLIF(REGEXP_REPLACE(mrr_gbp, '[£,\s]', '', 'g'), '')::NUMERIC(12,2) AS mrr_gbp,
        INITCAP(TRIM(plan_type))                                       AS plan_type,
        INITCAP(TRIM(status))                                          AS status,
        LOWER(TRIM(churn_reason))                                      AS churn_reason_key
    FROM raw.fact_subscriptions
),
deduplicated AS (
    -- Billing re-syncs create a second row for the same account-month with a
    -- new sub_id. Prefer the row that has an MRR value, then the original id.
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY account_id, billing_month
               ORDER BY (mrr_gbp IS NULL), (sub_id LIKE 'SUB-R%'), sub_id
           ) AS rn
    FROM standardised
),
carry_forward AS (
    -- Fill a missing MRR with the last known value for that account.
    -- COUNT() ignores nulls, so it only ticks up on rows that have a value,
    -- which groups each null with the populated row before it.
    SELECT d.*,
           COUNT(mrr_gbp) OVER (PARTITION BY account_id ORDER BY billing_month) AS fill_grp
    FROM deduplicated d
    WHERE rn = 1
),
filled AS (
    SELECT cf.*,
           FIRST_VALUE(mrr_gbp) OVER (PARTITION BY account_id, fill_grp
                                      ORDER BY billing_month)          AS mrr_filled
    FROM carry_forward cf
)
SELECT f.sub_id,
       f.account_id,
       f.billing_month,
       CASE WHEN f.status = 'Churned' THEN 0 ELSE COALESCE(f.mrr_filled, 0) END,
       (f.mrr_gbp IS NULL AND f.status = 'Active')                     AS mrr_imputed,
       f.plan_type,
       f.status,
       CASE WHEN f.status = 'Churned'
            THEN COALESCE(r.churn_reason, 'Not recorded') END          AS churn_reason
FROM filled f
LEFT JOIN core.ref_churn_reason r ON LOWER(r.churn_reason) = f.churn_reason_key
WHERE EXISTS (SELECT 1 FROM core.dim_customers c WHERE c.account_id = f.account_id);

-- Signup dates the CRM lost: use the first month we billed the account.
UPDATE core.dim_customers c
SET    signup_date = s.first_billing_month,
       signup_date_imputed = TRUE
FROM  (SELECT account_id, MIN(billing_month) AS first_billing_month
       FROM core.fact_subscriptions GROUP BY account_id) s
WHERE  c.account_id = s.account_id
  AND  c.signup_date IS NULL;

ALTER TABLE core.dim_customers ALTER COLUMN signup_date SET NOT NULL;


/* ----------------------------------------------------------------------------
   3. fact_support_tickets  (grain: one ticket)
   ------------------------------------------------------------------------- */
CREATE TABLE core.fact_support_tickets (
    ticket_id          VARCHAR(16)  PRIMARY KEY,
    account_id         VARCHAR(12)  NOT NULL REFERENCES core.dim_customers (account_id),
    created_at         TIMESTAMP    NOT NULL,
    resolved_at        TIMESTAMP,
    priority_code      CHAR(2)      NOT NULL REFERENCES core.ref_sla_policy (priority_code),
    category           VARCHAR(30)  NOT NULL,
    csat_score         SMALLINT     CHECK (csat_score BETWEEN 1 AND 5),
    is_open            BOOLEAN      NOT NULL,
    has_bad_timestamp  BOOLEAN      NOT NULL,
    resolution_hours   NUMERIC(10,2),
    sla_hours          INT          NOT NULL,
    sla_breached       BOOLEAN      -- NULL = cannot be judged yet / bad data
);

INSERT INTO core.fact_support_tickets
WITH standardised AS (
    SELECT
        TRIM(t.ticket_id)                                              AS ticket_id,
        UPPER(TRIM(t.account_id))                                      AS account_id,
        NULLIF(TRIM(t.created_at), '')::TIMESTAMP                      AS created_at,
        NULLIF(TRIM(t.resolved_at), '')::TIMESTAMP                     AS resolved_at,
        CASE
            WHEN LOWER(TRIM(t.priority)) IN ('p1', 'critical', 'p1 - critical') THEN 'P1'
            WHEN LOWER(TRIM(t.priority)) IN ('p2', 'high',     'p2 - high')     THEN 'P2'
            WHEN LOWER(TRIM(t.priority)) IN ('p3', 'medium',   'p3 - medium')   THEN 'P3'
            WHEN LOWER(TRIM(t.priority)) IN ('p4', 'low',      'p4 - low')      THEN 'P4'
        END                                                            AS priority_code,
        -- "Integration/API", "integration / api" -> "integration / api"
        REGEXP_REPLACE(LOWER(TRIM(t.category)), '\s*([/&])\s*', ' \1 ', 'g') AS category_key,
        NULLIF(TRIM(t.csat_score), '')::SMALLINT                       AS csat_raw
    FROM raw.fact_support_tickets t
),
deduplicated AS (
    -- The helpdesk webhook sometimes fires twice; the earlier copy can be
    -- captured before the ticket closed. Keep the most progressed version.
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY ticket_id
               ORDER BY (resolved_at IS NULL), resolved_at DESC, (csat_raw IS NULL)
           ) AS rn
    FROM standardised
)
SELECT
    d.ticket_id,
    d.account_id,
    d.created_at,
    CASE WHEN d.resolved_at < d.created_at THEN NULL ELSE d.resolved_at END,
    d.priority_code,
    c.category,
    CASE WHEN d.csat_raw BETWEEN 1 AND 5 THEN d.csat_raw END,
    (d.resolved_at IS NULL)                                            AS is_open,   -- bad-clock rows stay closed
    COALESCE(d.resolved_at < d.created_at, FALSE)                      AS has_bad_timestamp,
    CASE WHEN d.resolved_at >= d.created_at
         THEN ROUND(EXTRACT(EPOCH FROM d.resolved_at - d.created_at) / 3600.0, 2) END,
    p.sla_hours,
    CASE
        WHEN d.resolved_at < d.created_at THEN NULL                    -- unreliable clock
        WHEN d.resolved_at IS NOT NULL
             THEN d.resolved_at - d.created_at > p.sla_hours * INTERVAL '1 hour'
        -- still open: already breached if older than the SLA at snapshot time
        WHEN cfg.snapshot_ts - d.created_at > p.sla_hours * INTERVAL '1 hour' THEN TRUE
        ELSE NULL                                                      -- open, still inside SLA
    END
FROM deduplicated d
JOIN core.ref_sla_policy      p ON p.priority_code = d.priority_code
JOIN core.ref_ticket_category c ON c.category_key  = d.category_key
CROSS JOIN core.etl_config cfg
WHERE d.rn = 1
  AND EXISTS (SELECT 1 FROM core.dim_customers x WHERE x.account_id = d.account_id);


/* ----------------------------------------------------------------------------
   4. fact_product_usage  (grain: one account, one week - Monday snapshot)
   ------------------------------------------------------------------------- */
CREATE TABLE core.fact_product_usage (
    usage_id              VARCHAR(16)  PRIMARY KEY,
    account_id            VARCHAR(12)  NOT NULL REFERENCES core.dim_customers (account_id),
    activity_date         DATE         NOT NULL,
    active_users          INT          CHECK (active_users >= 0),
    api_calls             BIGINT       CHECK (api_calls >= 0),
    feature_adoption_pct  NUMERIC(5,1) CHECK (feature_adoption_pct BETWEEN 0 AND 100),
    CONSTRAINT uq_usage_account_week UNIQUE (account_id, activity_date)
);

INSERT INTO core.fact_product_usage
WITH standardised AS (
    SELECT
        TRIM(usage_id)                                                 AS usage_id,
        UPPER(TRIM(account_id))                                        AS account_id,
        TRIM(activity_date)::DATE                                      AS activity_date,
        NULLIF(TRIM(active_users), '')::INT                            AS active_users,
        NULLIF(TRIM(api_calls), '')::BIGINT                            AS api_calls,
        NULLIF(TRIM(feature_adoption_pct), '')::NUMERIC                AS adoption_raw
    FROM raw.fact_product_usage
),
deduplicated AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY account_id, activity_date
                              ORDER BY (usage_id LIKE 'USG-D%'), usage_id) AS rn
    FROM standardised
)
SELECT usage_id,
       account_id,
       activity_date,
       active_users,
       CASE WHEN api_calls >= 0 THEN api_calls END,                   -- -1 = collector bug
       CASE WHEN adoption_raw BETWEEN 0 AND 1   THEN ROUND(adoption_raw * 100, 1)
            WHEN adoption_raw BETWEEN 0 AND 100 THEN ROUND(adoption_raw, 1)
       END
FROM deduplicated d
WHERE rn = 1
  AND EXISTS (SELECT 1 FROM core.dim_customers x WHERE x.account_id = d.account_id);


/* ----------------------------------------------------------------------------
   5. Indexes for the reporting views
   ------------------------------------------------------------------------- */
CREATE INDEX ix_subs_month     ON core.fact_subscriptions   (billing_month);
CREATE INDEX ix_tickets_acct   ON core.fact_support_tickets (account_id, created_at);
CREATE INDEX ix_tickets_month  ON core.fact_support_tickets (created_at);
CREATE INDEX ix_usage_acct     ON core.fact_product_usage   (account_id, activity_date);


/* ----------------------------------------------------------------------------
   6. Data quality report - raw vs clean, so the fixes are auditable
   ------------------------------------------------------------------------- */
CREATE VIEW core.v_data_quality_report AS
SELECT 'dim_customers' AS table_name, 'Rows landed' AS check_name,
       COUNT(*) AS row_count FROM raw.dim_customers
UNION ALL SELECT 'dim_customers', 'Test accounts removed',
       COUNT(*) FROM raw.dim_customers WHERE company_name ILIKE 'TEST ACCOUNT%'
UNION ALL SELECT 'dim_customers', 'Duplicate CRM rows removed',
       (SELECT COUNT(*) FROM raw.dim_customers WHERE company_name NOT ILIKE 'TEST ACCOUNT%')
       - (SELECT COUNT(*) FROM core.dim_customers)
UNION ALL SELECT 'dim_customers', 'Signup dates imputed',
       COUNT(*) FROM core.dim_customers WHERE signup_date_imputed
UNION ALL SELECT 'dim_customers', 'UK-format dates parsed',
       COUNT(*) FROM raw.dim_customers WHERE signup_date ~ '^\d{2}/\d{2}/\d{4}$'
UNION ALL SELECT 'dim_customers', 'Unassigned account manager',
       COUNT(*) FROM core.dim_customers WHERE account_manager = 'Unassigned'
UNION ALL SELECT 'fact_subscriptions', 'Rows landed', COUNT(*) FROM raw.fact_subscriptions
UNION ALL SELECT 'fact_subscriptions', 'Rows after clean', COUNT(*) FROM core.fact_subscriptions
UNION ALL SELECT 'fact_subscriptions', 'Currency-formatted MRR parsed',
       COUNT(*) FROM raw.fact_subscriptions WHERE mrr_gbp LIKE '£%'
UNION ALL SELECT 'fact_subscriptions', 'Missing MRR carried forward',
       COUNT(*) FROM core.fact_subscriptions WHERE mrr_imputed
UNION ALL SELECT 'fact_subscriptions', 'Churn reason not recorded',
       COUNT(*) FROM core.fact_subscriptions WHERE churn_reason = 'Not recorded'
UNION ALL SELECT 'fact_support_tickets', 'Rows landed', COUNT(*) FROM raw.fact_support_tickets
UNION ALL SELECT 'fact_support_tickets', 'Rows after clean', COUNT(*) FROM core.fact_support_tickets
UNION ALL SELECT 'fact_support_tickets', 'Resolved-before-created flagged',
       COUNT(*) FROM core.fact_support_tickets WHERE has_bad_timestamp
UNION ALL SELECT 'fact_support_tickets', 'Invalid CSAT nulled',
       COUNT(*) FROM raw.fact_support_tickets WHERE TRIM(csat_score) IN ('0')
UNION ALL SELECT 'fact_product_usage', 'Rows landed', COUNT(*) FROM raw.fact_product_usage
UNION ALL SELECT 'fact_product_usage', 'Rows after clean', COUNT(*) FROM core.fact_product_usage
UNION ALL SELECT 'fact_product_usage', 'Negative API counts nulled',
       COUNT(*) FROM raw.fact_product_usage WHERE api_calls = '-1'
UNION ALL SELECT 'fact_product_usage', 'Adoption rescaled from 0-1',
       COUNT(*) FROM raw.fact_product_usage
       WHERE NULLIF(feature_adoption_pct, '')::NUMERIC BETWEEN 0 AND 1;

SELECT * FROM core.v_data_quality_report
ORDER BY table_name,
         CASE check_name WHEN 'Rows landed' THEN 0 WHEN 'Rows after clean' THEN 1 ELSE 2 END,
         check_name;
