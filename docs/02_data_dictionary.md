# Data dictionary

## Raw extracts (`data/raw/`, produced by `python/generate_data.py`)

### dim_customers.csv — CRM accounts
| Column | Description | Known issues in the extract |
|---|---|---|
| account_id | `NSC-10001` style key | Some accounts appear twice (CRM duplicates) |
| company_name | Legal name | Trailing spaces; 3 internal `TEST ACCOUNT` rows |
| industry | Sector | Mixed casing, leading spaces, ~2% blank |
| region | UK region or Ireland | Mixed casing |
| tier | SMB / Mid-Market / Enterprise | `ENTERPRISE`, `smb `, etc. |
| signup_date | Contract start | ISO and UK `DD/MM/YYYY` mixed, ~1% blank |
| account_manager | Owner | ~3% blank |

### fact_subscriptions.csv — monthly billing
| Column | Description | Known issues |
|---|---|---|
| sub_id | Billing line id | Re-sync duplicates carry a `SUB-R` id |
| account_id | FK to customers | Orphan rows for a test account |
| billing_month | First of month | – |
| mrr_gbp | Monthly recurring revenue | Some as `£1,234.00` text; ~0.4% blank on active rows |
| plan_type | Annual / Monthly | Mixed casing |
| status | Active / Churned | `ACTIVE`, ` churned` |
| churn_reason | Set on the churn month only | Mixed casing; ~8% blank |

### fact_support_tickets.csv — helpdesk
| Column | Description | Known issues |
|---|---|---|
| ticket_id | Ticket key | ~2% duplicated (webhook fired twice; some copies captured before close) |
| account_id | FK | – |
| created_at / resolved_at | Timestamps | `resolved_at` blank for open tickets; ~0.3% resolved *before* created |
| priority | P1–P4 | `P1 - Critical`, `critical`, `P1`, `Critical ` all mean the same |
| category | Ticket type | `Integration/API` vs `integration / api` |
| csat_score | 1–5 survey score | ~54% unanswered; a few `0` values |

### fact_product_usage.csv — weekly telemetry (Monday snapshots)
| Column | Description | Known issues |
|---|---|---|
| usage_id | Row key | ~1.5% duplicate snapshots (`USG-D` ids) |
| account_id | FK | – |
| activity_date | Week starting | – |
| active_users | Distinct users that week | ~0.5% blank |
| api_calls | API requests that week | `-1` from a collector bug |
| feature_adoption_pct | % of licensed features used | ~2% sent as 0–1 instead of 0–100 |

## Built-in behaviour (what the generator simulates)

- Every account has a hidden health score. P1/P2 SLA breaches push it down and the damage fades slowly.
- Health drives adoption, expansion, downgrades and churn. Annual contracts can only churn or downgrade at renewal.
- Support capacity drops from March 2025 and only partly recovers, so resolution times stretch.
- Signups peak in Q1 and September and dip in August and December. Tickets follow a similar seasonal pattern.
- Fixed random seed (42), so every run produces identical data.

## Warehouse layers

| Schema | Built by | Purpose |
|---|---|---|
| `raw` | `00_load_raw.sql` | Extracts landed as text, untouched |
| `core` | `01_schema_and_cleaning.sql` | Typed, de-duplicated, conformed tables with PK/FK/CHECK constraints, plus reference tables (`ref_sla_policy`, `ref_churn_reason`, `ref_ticket_category`) and `v_data_quality_report` |
| `mart` | `02_business_logic_views.sql` | Business logic and Power BI-facing views |

### Key mart views
| View | Grain | Use |
|---|---|---|
| `fact_mrr_movements` | account × month | MRR with movement type and amounts, renewal flag, months since signup |
| `v_mrr_bridge_monthly` | month | Opening → closing MRR bridge, logo churn, rolling 3-month churn, quick ratio |
| `v_nrr_monthly` | month × tier | TTM NRR, GRR and logo retention |
| `fact_support_tickets` | ticket | SLA outcome, hours over SLA, owning team |
| `v_support_sla_monthly` | month × priority | Compliance, rolling 3-month compliance, median resolution |
| `fact_renewals` | renewal event | Outcome plus support experience in the 90/180 days before |
| `v_account_health` | live account | Risk score and band for the action list |
| `dim_date`, `dim_customers`, `fact_product_usage` | – | Dimensions and usage for Power BI |
