/* ============================================================================
   02_business_logic_views.sql  -  Revenue, retention and SLA logic
   ----------------------------------------------------------------------------
   Target  : PostgreSQL 14+
   Run     : psql -d northstar -f sql/02_business_logic_views.sql
   Reads   : core.*
   Writes  : mart.*   (what Power BI connects to - nothing in Power BI should
                       need to re-derive a definition that lives here)

   Metric definitions (agreed with Finance - keep these in sync with the DAX):

     MRR                Recurring subscription revenue billed for the month, GBP.
     New MRR            First month an account is billed.
     Expansion MRR      Increase vs the account's previous month (upsell, seats, CPI).
     Contraction MRR    Decrease vs previous month while the account stays live.
     Churned MRR        Previous month's MRR for an account that stopped paying.
     Reactivation MRR   MRR from an account that previously churned and came back.
     Logo churn %       Accounts lost in the month / accounts live at start of month.
     NRR (TTM)          MRR today from accounts that were live 12 months ago,
                        divided by those same accounts' MRR 12 months ago.
                        Includes expansion; excludes new logos.
     GRR (TTM)          As NRR, but each account is capped at its starting MRR,
                        so expansion can't hide churn.
     SLA compliance     Tickets resolved within SLA / tickets whose SLA outcome
                        is known (open tickets count once they pass their SLA).

   Note: history starts Oct 2023, so Oct 2023 is an opening balance month, and
   12-month NRR is first available for Oct 2024.
   ========================================================================== */

DROP SCHEMA IF EXISTS mart CASCADE;
CREATE SCHEMA mart;


/* ----------------------------------------------------------------------------
   mart.dim_date  -  calendar, with UK fiscal year (April start)
   Power BI can use this or build its own (see powerbi/dim_date.dax).
   ------------------------------------------------------------------------- */
CREATE VIEW mart.dim_date AS
SELECT
    d::DATE                                                     AS date,
    DATE_TRUNC('month', d)::DATE                                AS month_start,
    EXTRACT(YEAR FROM d)::INT                                   AS year,
    EXTRACT(QUARTER FROM d)::INT                                AS quarter,
    'Q' || EXTRACT(QUARTER FROM d) || ' ' || EXTRACT(YEAR FROM d) AS quarter_label,
    EXTRACT(MONTH FROM d)::INT                                  AS month_number,
    TO_CHAR(d, 'Mon YYYY')                                      AS month_label,
    EXTRACT(YEAR FROM d)::INT * 100 + EXTRACT(MONTH FROM d)::INT AS year_month_key,
    -- UK fiscal year: FY2025/26 runs 1 Apr 2025 - 31 Mar 2026
    CASE WHEN EXTRACT(MONTH FROM d) >= 4
         THEN 'FY' || EXTRACT(YEAR FROM d) || '/' || RIGHT((EXTRACT(YEAR FROM d) + 1)::TEXT, 2)
         ELSE 'FY' || (EXTRACT(YEAR FROM d) - 1) || '/' || RIGHT(EXTRACT(YEAR FROM d)::TEXT, 2)
    END                                                         AS fiscal_year,
    EXTRACT(ISODOW FROM d) IN (6, 7)                            AS is_weekend
FROM GENERATE_SERIES('2020-01-01'::DATE, '2026-12-31'::DATE, INTERVAL '1 day') AS g(d);


/* ----------------------------------------------------------------------------
   mart.dim_customers  -  account attributes for slicing
   ------------------------------------------------------------------------- */
CREATE VIEW mart.dim_customers AS
SELECT
    c.account_id,
    c.company_name,
    c.industry,
    c.region,
    c.tier,
    CASE c.tier WHEN 'Enterprise' THEN 1 WHEN 'Mid-Market' THEN 2 ELSE 3 END AS tier_sort,
    c.account_manager,
    c.signup_date,
    DATE_TRUNC('month', c.signup_date)::DATE                    AS cohort_month,
    TO_CHAR(c.signup_date, 'YYYY') || '-Q' || EXTRACT(QUARTER FROM c.signup_date) AS cohort_quarter,
    c.signup_date < cfg.history_start                           AS is_pre_history_account,
    p.plan_type
FROM core.dim_customers c
CROSS JOIN core.etl_config cfg
LEFT JOIN LATERAL (   -- current (latest) plan type
    SELECT s.plan_type FROM core.fact_subscriptions s
    WHERE s.account_id = c.account_id
    ORDER BY s.billing_month DESC LIMIT 1
) p ON TRUE;


/* ----------------------------------------------------------------------------
   mart.fact_mrr_movements  -  one row per account per billed month,
   classified into the standard MRR bridge categories.
   ------------------------------------------------------------------------- */
CREATE VIEW mart.fact_mrr_movements AS
WITH ordered AS (
    SELECT
        s.account_id,
        s.billing_month                                         AS month_date,
        s.plan_type,
        s.status,
        s.churn_reason,
        s.mrr_gbp,
        c.signup_date,
        cfg.history_start,
        LAG(s.billing_month) OVER w                             AS prev_month,
        LAG(s.mrr_gbp)       OVER w                             AS prev_row_mrr,
        LEAD(s.status)       OVER w                             AS next_status,
        ROW_NUMBER()         OVER w                             AS row_seq
    FROM core.fact_subscriptions s
    JOIN core.dim_customers c USING (account_id)
    CROSS JOIN core.etl_config cfg
    WINDOW w AS (PARTITION BY s.account_id ORDER BY s.billing_month)
),
with_prev AS (
    SELECT o.*,
           -- If the previous row isn't last month, the account wasn't paying
           -- last month, so its opening MRR for this month is zero.
           CASE WHEN o.prev_month = (o.month_date - INTERVAL '1 month')::DATE
                THEN o.prev_row_mrr
                -- accounts already live when history starts: treat their first
                -- month as their opening position so the bridge reconciles
                WHEN o.row_seq = 1 AND o.month_date = o.history_start
                     AND o.signup_date < o.history_start THEN o.mrr_gbp
                ELSE 0 END                                      AS prev_mrr
    FROM ordered o
),
classified AS (
    SELECT w.*,
           CASE
               WHEN w.row_seq = 1 AND w.month_date = w.history_start
                    AND w.signup_date < w.history_start          THEN 'Opening balance'
               WHEN w.row_seq = 1                                THEN 'New'
               WHEN w.prev_mrr = 0 AND w.mrr_gbp > 0             THEN 'Reactivation'
               WHEN w.prev_mrr > 0 AND w.mrr_gbp = 0             THEN 'Churn'
               WHEN w.mrr_gbp > w.prev_mrr                       THEN 'Expansion'
               WHEN w.mrr_gbp < w.prev_mrr                       THEN 'Contraction'
               ELSE 'Retained (flat)'
           END                                                   AS movement_type
    FROM with_prev w
)
SELECT
    account_id,
    month_date,
    plan_type,
    movement_type,
    mrr_gbp,
    prev_mrr                                                     AS prev_mrr_gbp,
    mrr_gbp - prev_mrr                                           AS mrr_change_gbp,
    CASE WHEN movement_type = 'New'          THEN mrr_gbp              ELSE 0 END AS new_mrr_gbp,
    CASE WHEN movement_type = 'Expansion'    THEN mrr_gbp - prev_mrr   ELSE 0 END AS expansion_mrr_gbp,
    CASE WHEN movement_type = 'Contraction'  THEN prev_mrr - mrr_gbp   ELSE 0 END AS contraction_mrr_gbp,
    CASE WHEN movement_type = 'Churn'        THEN prev_mrr             ELSE 0 END AS churned_mrr_gbp,
    CASE WHEN movement_type = 'Reactivation' THEN mrr_gbp              ELSE 0 END AS reactivation_mrr_gbp,
    (mrr_gbp > 0)                                                AS is_active_logo,
    (prev_mrr > 0)                                               AS is_opening_logo,
    (movement_type = 'Churn')                                    AS is_churned_logo,
    churn_reason,
    -- the month before a churn: used to study warning signs
    (next_status = 'Churned')                                    AS churns_next_month,
    -- annual contracts renew on the signup anniversary
    (plan_type = 'Annual'
     AND (EXTRACT(YEAR FROM AGE(month_date, DATE_TRUNC('month', signup_date))) * 12
          + EXTRACT(MONTH FROM AGE(month_date, DATE_TRUNC('month', signup_date)))) > 0
     AND (EXTRACT(MONTH FROM AGE(month_date, DATE_TRUNC('month', signup_date)))) = 0)
                                                                 AS is_renewal_month,
    (EXTRACT(YEAR FROM AGE(month_date, DATE_TRUNC('month', signup_date))) * 12
     + EXTRACT(MONTH FROM AGE(month_date, DATE_TRUNC('month', signup_date))))::INT
                                                                 AS months_since_signup
FROM classified;


/* ----------------------------------------------------------------------------
   mart.v_mrr_bridge_monthly  -  the MRR waterfall, month by month
   Opening + New + Expansion - Contraction - Churn + Reactivation = Closing
   ------------------------------------------------------------------------- */
CREATE VIEW mart.v_mrr_bridge_monthly AS
WITH monthly AS (
    SELECT
        month_date,
        SUM(prev_mrr_gbp)                                       AS opening_mrr_gbp,
        SUM(new_mrr_gbp)                                        AS new_mrr_gbp,
        SUM(expansion_mrr_gbp)                                  AS expansion_mrr_gbp,
        SUM(contraction_mrr_gbp)                                AS contraction_mrr_gbp,
        SUM(churned_mrr_gbp)                                    AS churned_mrr_gbp,
        SUM(reactivation_mrr_gbp)                               AS reactivation_mrr_gbp,
        SUM(mrr_gbp)                                            AS closing_mrr_gbp,
        COUNT(*) FILTER (WHERE is_opening_logo)                 AS opening_logos,
        COUNT(*) FILTER (WHERE movement_type = 'New')           AS new_logos,
        COUNT(*) FILTER (WHERE is_churned_logo)                 AS churned_logos,
        COUNT(*) FILTER (WHERE is_active_logo)                  AS closing_logos
    FROM mart.fact_mrr_movements
    GROUP BY month_date
)
SELECT
    m.*,
    -- reconciliation check: should always be zero
    m.closing_mrr_gbp - (m.opening_mrr_gbp + m.new_mrr_gbp + m.expansion_mrr_gbp
        - m.contraction_mrr_gbp - m.churned_mrr_gbp + m.reactivation_mrr_gbp)
                                                                AS bridge_check_gbp,
    ROUND(100.0 * (m.closing_mrr_gbp - LAG(m.closing_mrr_gbp) OVER w)
          / NULLIF(LAG(m.closing_mrr_gbp) OVER w, 0), 2)        AS mom_mrr_growth_pct,
    ROUND(100.0 * m.churned_logos / NULLIF(m.opening_logos, 0), 2) AS logo_churn_pct,
    ROUND(100.0 * m.churned_mrr_gbp / NULLIF(m.opening_mrr_gbp, 0), 2) AS gross_mrr_churn_pct,
    -- rolling 3 months: total churned logos / total opening logos
    ROUND(100.0 * SUM(m.churned_logos) OVER r3
          / NULLIF(SUM(m.opening_logos) OVER r3, 0), 2)         AS logo_churn_pct_r3m,
    -- quick ratio: growth bought per £1 lost
    ROUND((m.new_mrr_gbp + m.expansion_mrr_gbp + m.reactivation_mrr_gbp)
          / NULLIF(m.contraction_mrr_gbp + m.churned_mrr_gbp, 0), 2) AS quick_ratio,
    SUM(m.new_mrr_gbp) OVER ytd                                 AS new_mrr_ytd_gbp
FROM monthly m
WINDOW w   AS (ORDER BY m.month_date),
       r3  AS (ORDER BY m.month_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
       ytd AS (PARTITION BY EXTRACT(YEAR FROM m.month_date) ORDER BY m.month_date);


/* ----------------------------------------------------------------------------
   mart.v_nrr_monthly  -  trailing-12-month NRR and GRR, overall and by tier
   ------------------------------------------------------------------------- */
CREATE VIEW mart.v_nrr_monthly AS
WITH base AS (
    SELECT m.account_id, m.month_date, m.mrr_gbp, c.tier
    FROM mart.fact_mrr_movements m
    JOIN core.dim_customers c USING (account_id)
),
paired AS (
    -- each account live 12 months ago, with what it pays now (0 if gone)
    SELECT
        (b0.month_date + INTERVAL '12 months')::DATE            AS month_date,
        b0.tier,
        b0.mrr_gbp                                              AS mrr_12m_ago,
        COALESCE(b1.mrr_gbp, 0)                                 AS mrr_now
    FROM base b0
    LEFT JOIN base b1
           ON b1.account_id = b0.account_id
          AND b1.month_date = (b0.month_date + INTERVAL '12 months')::DATE
    WHERE b0.mrr_gbp > 0
      AND b0.month_date + INTERVAL '12 months' <= (SELECT last_full_month FROM core.etl_config)
)
SELECT
    month_date,
    COALESCE(tier, 'All tiers')                                 AS tier,
    COUNT(*)                                                    AS base_accounts,
    SUM(mrr_12m_ago)                                            AS base_mrr_gbp,
    SUM(mrr_now)                                                AS retained_mrr_gbp,
    ROUND(100.0 * SUM(mrr_now) / NULLIF(SUM(mrr_12m_ago), 0), 1)               AS nrr_ttm_pct,
    ROUND(100.0 * SUM(LEAST(mrr_now, mrr_12m_ago)) / NULLIF(SUM(mrr_12m_ago), 0), 1) AS grr_ttm_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE mrr_now > 0) / COUNT(*), 1)           AS logo_retention_ttm_pct
FROM paired
GROUP BY GROUPING SETS ((month_date), (month_date, tier));


/* ----------------------------------------------------------------------------
   mart.fact_support_tickets  -  ticket fact for Power BI
   ------------------------------------------------------------------------- */
CREATE VIEW mart.fact_support_tickets AS
SELECT
    t.ticket_id,
    t.account_id,
    t.created_at,
    t.created_at::DATE                                          AS created_date,
    DATE_TRUNC('month', t.created_at)::DATE                     AS created_month,
    t.resolved_at,
    t.priority_code,
    p.priority_label,
    p.is_high_priority,
    t.category,
    rc.owning_team,
    t.csat_score,
    t.is_open,
    t.resolution_hours,
    t.sla_hours,
    t.sla_breached,
    (t.sla_breached IS NOT NULL)                                AS sla_evaluable,
    -- how far past SLA, in hours: sizes the backlog problem, not just counts it
    CASE WHEN t.sla_breached AND t.resolution_hours IS NOT NULL
         THEN t.resolution_hours - t.sla_hours END              AS hours_over_sla
FROM core.fact_support_tickets t
JOIN core.ref_sla_policy      p  USING (priority_code)
JOIN core.ref_ticket_category rc ON rc.category = t.category;


/* ----------------------------------------------------------------------------
   mart.v_support_sla_monthly  -  SLA compliance by month and priority
   ------------------------------------------------------------------------- */
CREATE VIEW mart.v_support_sla_monthly AS
WITH monthly AS (
    SELECT
        created_month                                           AS month_date,
        priority_code,
        COUNT(*)                                                AS tickets,
        COUNT(*) FILTER (WHERE sla_evaluable)                   AS sla_evaluable,
        COUNT(*) FILTER (WHERE sla_breached)                    AS sla_breaches,
        ROUND(AVG(resolution_hours), 1)                         AS avg_resolution_hrs,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_hours)::NUMERIC, 1)
                                                                AS median_resolution_hrs,
        ROUND(AVG(csat_score), 2)                               AS avg_csat
    FROM mart.fact_support_tickets
    GROUP BY created_month, priority_code
)
SELECT
    m.*,
    ROUND(100.0 * (m.sla_evaluable - m.sla_breaches) / NULLIF(m.sla_evaluable, 0), 1)
                                                                AS sla_compliance_pct,
    ROUND(100.0 * (SUM(m.sla_evaluable) OVER r3 - SUM(m.sla_breaches) OVER r3)
          / NULLIF(SUM(m.sla_evaluable) OVER r3, 0), 1)         AS sla_compliance_r3m_pct,
    m.tickets - LAG(m.tickets, 12) OVER (PARTITION BY m.priority_code ORDER BY m.month_date)
                                                                AS tickets_vs_same_month_ly
FROM monthly m
WINDOW r3 AS (PARTITION BY m.priority_code ORDER BY m.month_date
              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW);


/* ----------------------------------------------------------------------------
   mart.fact_product_usage  -  weekly usage, passed through for Power BI
   ------------------------------------------------------------------------- */
CREATE VIEW mart.fact_product_usage AS
SELECT usage_id, account_id, activity_date,
       DATE_TRUNC('month', activity_date)::DATE AS activity_month,
       active_users, api_calls, feature_adoption_pct
FROM core.fact_product_usage;


/* ----------------------------------------------------------------------------
   mart.fact_renewals  -  every annual contract renewal decision
   Used for "do support experience and CSAT predict renewal?"
   ------------------------------------------------------------------------- */
CREATE VIEW mart.fact_renewals AS
SELECT
    m.account_id,
    m.month_date                                                AS renewal_month,
    m.prev_mrr_gbp                                              AS mrr_before_gbp,
    m.mrr_gbp                                                   AS mrr_after_gbp,
    CASE WHEN m.mrr_gbp = 0               THEN 'Churned'
         WHEN m.mrr_gbp < m.prev_mrr_gbp  THEN 'Renewed - downgraded'
         WHEN m.mrr_gbp > m.prev_mrr_gbp * 1.05 THEN 'Renewed - expanded'
         ELSE 'Renewed - flat'
    END                                                         AS renewal_outcome,
    (m.mrr_gbp > 0)                                             AS is_renewed,
    sup.hp_breaches_90d,
    sup.tickets_180d,
    sup.avg_csat_180d,
    CASE WHEN sup.avg_csat_180d IS NULL THEN 'No responses'
         WHEN sup.avg_csat_180d < 3     THEN '1. Below 3.0'
         WHEN sup.avg_csat_180d < 4     THEN '2. 3.0 - 3.9'
         ELSE                                '3. 4.0 and above'
    END                                                         AS csat_band
FROM mart.fact_mrr_movements m
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) FILTER (WHERE t.sla_breached AND t.is_high_priority
                         AND t.created_at >= m.month_date - INTERVAL '90 days') AS hp_breaches_90d,
        COUNT(*)                                                AS tickets_180d,
        ROUND(AVG(t.csat_score), 2)                             AS avg_csat_180d
    FROM mart.fact_support_tickets t
    WHERE t.account_id = m.account_id
      AND t.created_at >= m.month_date - INTERVAL '180 days'
      AND t.created_at <  m.month_date
) sup ON TRUE
WHERE m.is_renewal_month
  AND m.prev_mrr_gbp > 0;


/* ----------------------------------------------------------------------------
   mart.v_account_health  -  one row per live account, as at the last month.
   Risk rules (same rule is used by the DAX measure "High-Risk Revenue at Risk"):
     HIGH   : 2+ high-priority SLA breaches in the last 90 days AND adoption
              below 50% (two warning signs at once)
              OR average feature adoption below 35% over the last 13 weeks
     MEDIUM : 1 high-priority breach, adoption 35-50%, adoption falling 5+ pts,
              or average CSAT below 3.5
     LOW    : everything else
   ------------------------------------------------------------------------- */
CREATE VIEW mart.v_account_health AS
WITH cfg AS (
    SELECT snapshot_ts, last_full_month FROM core.etl_config
),
live AS (
    SELECT m.account_id, m.mrr_gbp, m.plan_type
    FROM mart.fact_mrr_movements m, cfg
    WHERE m.month_date = cfg.last_full_month AND m.mrr_gbp > 0
),
support AS (
    SELECT t.account_id,
           COUNT(*) FILTER (WHERE t.created_at >= cfg.snapshot_ts - INTERVAL '90 days')      AS tickets_90d,
           COUNT(*) FILTER (WHERE t.sla_breached AND t.is_high_priority
                            AND t.created_at >= cfg.snapshot_ts - INTERVAL '90 days')        AS hp_breaches_90d,
           COUNT(*) FILTER (WHERE t.sla_breached
                            AND t.created_at >= cfg.snapshot_ts - INTERVAL '90 days')        AS all_breaches_90d,
           ROUND(AVG(t.resolution_hours) FILTER (
                 WHERE t.created_at >= cfg.snapshot_ts - INTERVAL '90 days'), 1)            AS avg_resolution_hrs_90d,
           ROUND(AVG(t.csat_score) FILTER (
                 WHERE t.created_at >= cfg.snapshot_ts - INTERVAL '180 days'), 2)           AS avg_csat_180d,
           COUNT(*) FILTER (WHERE t.is_open)                                                 AS open_tickets
    FROM mart.fact_support_tickets t, cfg
    GROUP BY t.account_id
),
usage AS (
    SELECT u.account_id,
           ROUND(AVG(u.feature_adoption_pct) FILTER (
                 WHERE u.activity_date > cfg.snapshot_ts - INTERVAL '91 days'), 1)          AS adoption_13w,
           ROUND(AVG(u.feature_adoption_pct) FILTER (
                 WHERE u.activity_date >  cfg.snapshot_ts - INTERVAL '28 days'), 1)         AS adoption_last_4w,
           ROUND(AVG(u.feature_adoption_pct) FILTER (
                 WHERE u.activity_date <= cfg.snapshot_ts - INTERVAL '28 days'
                   AND u.activity_date >  cfg.snapshot_ts - INTERVAL '84 days'), 1)         AS adoption_prior_8w,
           ROUND(AVG(u.active_users) FILTER (
                 WHERE u.activity_date >  cfg.snapshot_ts - INTERVAL '28 days'), 1)         AS active_users_last_4w
    FROM core.fact_product_usage u, cfg
    WHERE u.activity_date > cfg.snapshot_ts - INTERVAL '120 days'
    GROUP BY u.account_id
),
scored AS (
    SELECT
        l.account_id, c.company_name, c.tier, c.region, c.industry, c.account_manager,
        l.plan_type, l.mrr_gbp, l.mrr_gbp * 12 AS arr_gbp,
        -- next annual renewal: the next signup anniversary after the snapshot
        CASE WHEN l.plan_type = 'Annual' THEN
            (DATE_TRUNC('month', c.signup_date)
             + (EXTRACT(YEAR FROM AGE(cfg.last_full_month, DATE_TRUNC('month', c.signup_date))) + 1)
               * INTERVAL '1 year')::DATE
        END                                                     AS next_renewal_month,
        COALESCE(s.tickets_90d, 0)      AS tickets_90d,
        COALESCE(s.hp_breaches_90d, 0)  AS hp_breaches_90d,
        COALESCE(s.all_breaches_90d, 0) AS all_breaches_90d,
        s.avg_resolution_hrs_90d,
        s.avg_csat_180d,
        COALESCE(s.open_tickets, 0)     AS open_tickets,
        u.adoption_13w,
        u.adoption_last_4w,
        u.adoption_prior_8w,
        u.adoption_last_4w - u.adoption_prior_8w AS adoption_trend_pts,
        u.active_users_last_4w
    FROM live l
    JOIN core.dim_customers c USING (account_id)
    CROSS JOIN cfg
    LEFT JOIN support s USING (account_id)
    LEFT JOIN usage   u USING (account_id)
)
SELECT
    sc.*,
    -- 0-100 score for ranking within a band (higher = worse)
    LEAST(100, ROUND(
          20 * LEAST(sc.hp_breaches_90d, 3)
        + 0.8 * GREATEST(0, 60 - COALESCE(sc.adoption_13w, 60))
        + 1.5 * GREATEST(0, -COALESCE(sc.adoption_trend_pts, 0))
        + 8  * GREATEST(0, 4 - COALESCE(sc.avg_csat_180d, 4))
    ))                                                          AS risk_score,
    CASE
        WHEN (sc.hp_breaches_90d >= 2 AND sc.adoption_13w < 50)
          OR sc.adoption_13w < 35                                  THEN 'High'
        WHEN sc.hp_breaches_90d >= 1 OR sc.adoption_13w < 50
          OR sc.adoption_trend_pts <= -5 OR sc.avg_csat_180d < 3.5 THEN 'Medium'
        ELSE 'Low'
    END                                                         AS risk_band
FROM scored sc;
