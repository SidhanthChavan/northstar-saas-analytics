/* ============================================================================
   03_ad_hoc_investigation.sql  -  Four stakeholder questions, answered
   ----------------------------------------------------------------------------
   Target  : PostgreSQL 14+
   Run     : psql -d northstar -f sql/03_ad_hoc_investigation.sql
   Reads   : mart.*, core.*

   Q1  CRO:  "Are newer customers sticking around as well as older cohorts?"
   Q2  VP Customer Success:  "Which Enterprise accounts does my team call this week?"
   Q3  CFO:  "Is the support backlog actually costing us renewals, and how much?"
   Q4  Head of Support:  "Where exactly is the queue breaking down?"
   ========================================================================== */


/* ----------------------------------------------------------------------------
   Q1. Cohort retention by signup quarter
   Logo retention = share of the cohort still paying N months after signup.
   Revenue retention (M12) = cohort MRR at month 12 / cohort MRR at month 0,
   so expansion can push it above 100%.
   NULL means the cohort isn't old enough yet - not zero retention.
   ------------------------------------------------------------------------- */
\echo '== Q1. Cohort retention by signup quarter =='

WITH cohort_members AS (
    SELECT m.account_id,
           c.cohort_quarter,
           m.mrr_gbp                                            AS starting_mrr
    FROM mart.fact_mrr_movements m
    JOIN mart.dim_customers c USING (account_id)
    WHERE m.movement_type = 'New'
),
cohort_activity AS (
    SELECT cm.cohort_quarter, cm.account_id, cm.starting_mrr,
           m.months_since_signup, m.mrr_gbp
    FROM cohort_members cm
    JOIN mart.fact_mrr_movements m USING (account_id)
),
summary AS (
    SELECT
        cohort_quarter,
        COUNT(DISTINCT account_id)                                       AS cohort_size,
        SUM(starting_mrr) FILTER (WHERE months_since_signup = 0)         AS starting_mrr_gbp,
        COUNT(*) FILTER (WHERE months_since_signup = 3  AND mrr_gbp > 0) AS live_m3,
        COUNT(*) FILTER (WHERE months_since_signup = 6  AND mrr_gbp > 0) AS live_m6,
        COUNT(*) FILTER (WHERE months_since_signup = 12 AND mrr_gbp > 0) AS live_m12,
        COUNT(*) FILTER (WHERE months_since_signup = 18 AND mrr_gbp > 0) AS live_m18,
        COUNT(*) FILTER (WHERE months_since_signup = 24 AND mrr_gbp > 0) AS live_m24,
        SUM(mrr_gbp) FILTER (WHERE months_since_signup = 12)             AS mrr_m12_gbp
    FROM cohort_activity
    GROUP BY cohort_quarter
),
observable AS (
    -- months between the END of the cohort quarter and the last data month:
    -- every member has reached milestone N only if this is >= N
    SELECT s.*,
           (EXTRACT(YEAR FROM AGE(cfg.last_full_month,
                (TO_DATE(LEFT(s.cohort_quarter, 4) || '-01-01', 'YYYY-MM-DD')
                 + (RIGHT(s.cohort_quarter, 1)::INT * 3 - 1) * INTERVAL '1 month')::DATE)) * 12
          + EXTRACT(MONTH FROM AGE(cfg.last_full_month,
                (TO_DATE(LEFT(s.cohort_quarter, 4) || '-01-01', 'YYYY-MM-DD')
                 + (RIGHT(s.cohort_quarter, 1)::INT * 3 - 1) * INTERVAL '1 month')::DATE)))::INT
                                                                         AS full_months_observed
    FROM summary s CROSS JOIN core.etl_config cfg
)
SELECT
    cohort_quarter,
    cohort_size,
    starting_mrr_gbp,
    CASE WHEN full_months_observed >= 3  THEN ROUND(100.0 * live_m3  / cohort_size, 1) END AS logo_ret_m3_pct,
    CASE WHEN full_months_observed >= 6  THEN ROUND(100.0 * live_m6  / cohort_size, 1) END AS logo_ret_m6_pct,
    CASE WHEN full_months_observed >= 12 THEN ROUND(100.0 * live_m12 / cohort_size, 1) END AS logo_ret_m12_pct,
    CASE WHEN full_months_observed >= 18 THEN ROUND(100.0 * live_m18 / cohort_size, 1) END AS logo_ret_m18_pct,
    CASE WHEN full_months_observed >= 24 THEN ROUND(100.0 * live_m24 / cohort_size, 1) END AS logo_ret_m24_pct,
    CASE WHEN full_months_observed >= 12
         THEN ROUND(100.0 * mrr_m12_gbp / NULLIF(starting_mrr_gbp, 0), 1) END          AS revenue_ret_m12_pct
FROM observable
ORDER BY cohort_quarter;


/* ----------------------------------------------------------------------------
   Q2. At-risk Enterprise accounts - the call list
   High-risk Enterprise accounts, renewals inside 6 months first, then by
   revenue. The "next step" column is a starting point for the CSM, not a
   replacement for knowing the customer.
   ------------------------------------------------------------------------- */
\echo '== Q2. At-risk Enterprise accounts =='

SELECT
    h.account_id,
    h.company_name,
    h.account_manager,
    h.region,
    h.mrr_gbp,
    h.arr_gbp,
    h.next_renewal_month,
    (h.next_renewal_month - cfg.last_full_month) / 30            AS months_to_renewal,
    h.hp_breaches_90d,
    h.open_tickets,
    h.avg_csat_180d,
    h.adoption_13w,
    h.adoption_trend_pts,
    h.risk_score,
    CASE
        WHEN h.hp_breaches_90d >= 2 AND h.next_renewal_month
             <= cfg.last_full_month + INTERVAL '3 months'
             THEN 'Exec sponsor call this week; review open P1/P2s before renewal talks'
        WHEN h.hp_breaches_90d >= 2
             THEN 'Move to priority support queue; service review with customer'
        WHEN h.adoption_13w < 35
             THEN 'CSM adoption plan: re-onboard key users, agree usage goals'
        ELSE 'CSM health check'
    END                                                          AS suggested_next_step
FROM mart.v_account_health h
CROSS JOIN core.etl_config cfg
WHERE h.tier = 'Enterprise'
  AND h.risk_band = 'High'
ORDER BY (h.next_renewal_month <= cfg.last_full_month + INTERVAL '6 months') DESC NULLS LAST,
         h.mrr_gbp DESC;

-- Headline for the exec summary
SELECT
    COUNT(*)                                                     AS high_risk_enterprise_accounts,
    SUM(h.arr_gbp)                                               AS high_risk_enterprise_arr_gbp,
    COUNT(*) FILTER (WHERE h.next_renewal_month
                     <= cfg.last_full_month + INTERVAL '6 months') AS renewing_within_6m,
    SUM(h.arr_gbp) FILTER (WHERE h.next_renewal_month
                     <= cfg.last_full_month + INTERVAL '6 months') AS arr_renewing_within_6m_gbp
FROM mart.v_account_health h
CROSS JOIN core.etl_config cfg
WHERE h.tier = 'Enterprise' AND h.risk_band = 'High';


/* ----------------------------------------------------------------------------
   Q3. Do high-priority SLA breaches predict churn? How much ARR is exposed?
   Method: take every account live at the start of each quarter, count its
   P1/P2 SLA breaches in that quarter, then check whether it churned in the
   following 6 months. Only quarters with a full 6-month look-ahead are used,
   so nothing is judged on incomplete data.
   ------------------------------------------------------------------------- */
\echo '== Q3a. Churn in the next 6 months by high-priority breaches in a quarter =='

WITH quarters AS (
    SELECT q::DATE AS q_start, (q + INTERVAL '3 months')::DATE AS q_end
    FROM core.etl_config cfg,
         GENERATE_SERIES(cfg.history_start, cfg.last_full_month, INTERVAL '3 months') q
    WHERE q + INTERVAL '9 months' <= cfg.last_full_month + INTERVAL '1 month'
),
panel AS (
    SELECT
        m.account_id,
        q.q_start,
        c.tier,
        m.mrr_gbp,
        (SELECT COUNT(*) FROM mart.fact_support_tickets t
         WHERE t.account_id = m.account_id AND t.is_high_priority AND t.sla_breached
           AND t.created_at >= q.q_start AND t.created_at < q.q_end)       AS hp_breaches,
        EXISTS (SELECT 1 FROM mart.fact_mrr_movements x
                WHERE x.account_id = m.account_id AND x.is_churned_logo
                  AND x.month_date >= q.q_end
                  AND x.month_date <  q.q_end + INTERVAL '6 months')       AS churned_next_6m
    FROM quarters q
    JOIN mart.fact_mrr_movements m ON m.month_date = q.q_start AND m.mrr_gbp > 0
    JOIN core.dim_customers c USING (account_id)
),
banded AS (
    SELECT *,
           CASE WHEN hp_breaches = 0 THEN '0 breaches'
                WHEN hp_breaches = 1 THEN '1 breach'
                WHEN hp_breaches = 2 THEN '2 breaches'
                ELSE '3+ breaches' END                                     AS breach_band
    FROM panel
),
baseline AS (
    SELECT AVG(churned_next_6m::INT) AS base_rate FROM banded WHERE hp_breaches = 0
)
SELECT
    b.breach_band,
    COUNT(*)                                                     AS account_quarters,
    ROUND(100.0 * AVG(b.churned_next_6m::INT), 1)                AS churn_next_6m_pct,
    ROUND(AVG(b.churned_next_6m::INT) / bl.base_rate, 1)         AS x_vs_no_breach_baseline,
    ROUND(100.0 * SUM(b.mrr_gbp * b.churned_next_6m::INT) / SUM(b.mrr_gbp), 1)
                                                                 AS mrr_weighted_churn_pct
FROM banded b CROSS JOIN baseline bl
GROUP BY b.breach_band, bl.base_rate
ORDER BY b.breach_band;

-- Same question, Enterprise only (where the money is)
\echo '== Q3b. Enterprise only =='
WITH quarters AS (
    SELECT q::DATE AS q_start, (q + INTERVAL '3 months')::DATE AS q_end
    FROM core.etl_config cfg,
         GENERATE_SERIES(cfg.history_start, cfg.last_full_month, INTERVAL '3 months') q
    WHERE q + INTERVAL '9 months' <= cfg.last_full_month + INTERVAL '1 month'
),
panel AS (
    SELECT m.account_id,
           (SELECT COUNT(*) FROM mart.fact_support_tickets t
            WHERE t.account_id = m.account_id AND t.is_high_priority AND t.sla_breached
              AND t.created_at >= q.q_start AND t.created_at < q.q_end)    AS hp_breaches,
           EXISTS (SELECT 1 FROM mart.fact_mrr_movements x
                   WHERE x.account_id = m.account_id AND x.is_churned_logo
                     AND x.month_date >= q.q_end
                     AND x.month_date <  q.q_end + INTERVAL '6 months')    AS churned_next_6m
    FROM quarters q
    JOIN mart.fact_mrr_movements m ON m.month_date = q.q_start AND m.mrr_gbp > 0
    JOIN core.dim_customers c ON c.account_id = m.account_id AND c.tier = 'Enterprise'
)
SELECT
    CASE WHEN hp_breaches <= 2 THEN '0-2 breaches' ELSE '3+ breaches' END  AS breach_band,
    COUNT(*)                                                     AS account_quarters,
    ROUND(100.0 * AVG(churned_next_6m::INT), 1)                  AS churn_next_6m_pct
FROM panel
GROUP BY 1 ORDER BY 1;

-- Q3c. Exposure today: ARR on accounts that breached 3+ P1/P2s in the
-- last 90 days, and the churn we'd expect on top of the baseline. This is
-- the size of the prize for fixing priority routing.
\echo '== Q3c. ARR exposed to breach-driven churn right now =='
WITH quarters AS (
    SELECT q::DATE AS q_start, (q + INTERVAL '3 months')::DATE AS q_end
    FROM core.etl_config cfg,
         GENERATE_SERIES(cfg.history_start, cfg.last_full_month, INTERVAL '3 months') q
    WHERE q + INTERVAL '9 months' <= cfg.last_full_month + INTERVAL '1 month'
),
panel AS (
    SELECT (SELECT COUNT(*) FROM mart.fact_support_tickets t
            WHERE t.account_id = m.account_id AND t.is_high_priority AND t.sla_breached
              AND t.created_at >= q.q_start AND t.created_at < q.q_end)    AS hp_breaches,
           EXISTS (SELECT 1 FROM mart.fact_mrr_movements x
                   WHERE x.account_id = m.account_id AND x.is_churned_logo
                     AND x.month_date >= q.q_end
                     AND x.month_date <  q.q_end + INTERVAL '6 months')    AS churned_next_6m
    FROM quarters q
    JOIN mart.fact_mrr_movements m ON m.month_date = q.q_start AND m.mrr_gbp > 0
),
rates AS (
    SELECT AVG(churned_next_6m::INT) FILTER (WHERE hp_breaches = 0)  AS base_rate,
           AVG(churned_next_6m::INT) FILTER (WHERE hp_breaches >= 3) AS breach_rate
    FROM panel
)
SELECT
    COUNT(*)                                                     AS live_accounts_with_3plus_breaches,
    SUM(h.arr_gbp)                                               AS arr_gbp,
    ROUND(100 * r.base_rate, 1)                                  AS baseline_6m_churn_pct,
    ROUND(100 * r.breach_rate, 1)                                AS breach_6m_churn_pct,
    ROUND(SUM(h.arr_gbp) * (r.breach_rate - r.base_rate), -3)    AS excess_arr_at_risk_6m_gbp
FROM mart.v_account_health h
CROSS JOIN rates r
WHERE h.hp_breaches_90d >= 3
GROUP BY r.base_rate, r.breach_rate;


/* ----------------------------------------------------------------------------
   Q4. Support bottleneck: which queue broke when capacity dropped?
   Compares the same six calendar months before the hiring freeze (Apr-Sep
   2024) and now (Apr-Sep 2026), so seasonality cancels out.
   "Share of hours over SLA" shows where the overrun actually sits - a queue
   can have a modest breach rate but own most of the late hours.
   ------------------------------------------------------------------------- */
\echo '== Q4. Support bottleneck by category, before vs after the freeze =='

WITH periods AS (
    SELECT t.*,
           CASE WHEN t.created_at >= '2024-04-01' AND t.created_at < '2024-10-01' THEN '1. Apr-Sep 2024'
                WHEN t.created_at >= '2026-04-01' AND t.created_at < '2026-10-01' THEN '2. Apr-Sep 2026'
           END                                                   AS period
    FROM mart.fact_support_tickets t
),
by_cat AS (
    SELECT
        category,
        owning_team,
        period,
        COUNT(*)                                                 AS tickets,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_hours)::NUMERIC, 1) AS p50_hrs,
        ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY resolution_hours)::NUMERIC, 1) AS p90_hrs,
        ROUND(100.0 * COUNT(*) FILTER (WHERE sla_breached)
              / NULLIF(COUNT(*) FILTER (WHERE sla_evaluable), 0), 1) AS breach_pct,
        SUM(hours_over_sla)                                      AS hours_over_sla
    FROM periods
    WHERE period IS NOT NULL
    GROUP BY category, owning_team, period
)
SELECT
    b.category,
    b.owning_team,
    b.period,
    b.tickets,
    b.p50_hrs,
    b.p90_hrs,
    b.breach_pct,
    ROUND(100.0 * b.hours_over_sla / SUM(b.hours_over_sla) OVER (PARTITION BY b.period), 1)
                                                                 AS share_of_hours_over_sla_pct,
    b.breach_pct - LAG(b.breach_pct) OVER (PARTITION BY b.category ORDER BY b.period)
                                                                 AS breach_pct_change_pts
FROM by_cat b
ORDER BY b.period DESC, share_of_hours_over_sla_pct DESC;
