# Dashboard wireframe and UX spec

Three pages, each built around one leadership conversation. The test for every visual: would someone in the Monday leadership meeting change a decision because of it? If not, it's cut.

## Global conventions

| Setting | Value |
|---|---|
| Canvas | 16:9, 1280 × 720, 8 px grid, 16 px outer margin |
| Font | Segoe UI. Titles 14 pt semibold, card values 28 pt, labels 10 pt |
| Currency | `£#,0` for MRR, `£#,0.0,,"m"` for ARR, `£#,0,"k"` on axes |
| Percentages | `0.0%`. Deltas show sign and arrow: ▲ 1.2% / ▼ 0.8% |
| Colour | Navy `#1B2A41` (primary data), Teal `#2A9D8F` (positive / retained), Amber `#E9A23B` (watch), Red `#C42B1C` (breach / churn / high risk), Grey `#8A8886` (context, prior period). Red is used **only** for bad news, so it means something when it appears. |
| Theme file | `powerbi/northstar_theme.json` (View → Themes → Browse for themes) |
| Header band | 48 px: page title on the left, "Data to: Sep 2026" (`[Last Data Month]`) on the right |
| Slicer panel | Collapsible left pane, 200 px, synced across all three pages |

### Synced slicers (all pages)

| Slicer | Field | Style | Default |
|---|---|---|---|
| Month | `dim_date[month_label]` | Dropdown, single select | Latest month |
| Tier | `dim_customers[tier]` | Tile buttons (Enterprise / Mid-Market / SMB) | All |
| Region | `dim_customers[region]` | Dropdown, multi-select | All |
| Account manager | `dim_customers[account_manager]` | Dropdown with search | All |

Trend visuals use **Edit interactions → None** from the Month slicer and their own visual-level filter of *last 24 months*, so a trend always shows the run-up to the selected month instead of collapsing to one point. KPI cards respond to the Month slicer.

---

## Page 1 — Executive Revenue & Retention Overview

**Audience:** CEO, CFO, CRO. **The question:** are we growing, and is the growth the right kind?

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Revenue & Retention Overview                               Data to: Sep 2026 │
├────────────┬────────────┬────────────┬────────────┬────────────┬─────────────┤
│ Total MRR  │ ARR        │ NRR (TTM)  │ Logo churn │ Active     │ Revenue at  │
│ £3.22m     │ £38.6m     │ 94.9%      │ (R3M) 1.35%│ customers  │ risk (High) │
│ ▲0.1% MoM  │            │ ▼1.7 pts   │ per month  │ 1,179      │ £397k MRR   │
├────────────┴────────────┴──────────┬─┴────────────┴────────────┴─────────────┤
│ A. MRR bridge (waterfall)          │ B. NRR & GRR trend (line)               │
│    Opening → New → Exp → React     │    24 months, 100% reference line       │
│    → Contr → Churn → Closing       │                                         │
├────────────────────────────────────┼─────────────────────────────────────────┤
│ C. MRR by tier (stacked area)      │ D. MRR by region (bar)  │ E. Movement   │
│    24 months                       │                         │    table      │
└────────────────────────────────────┴─────────────────────────┴───────────────┘
```

### KPI cards (row 1)

Use the **new card visual** with reference labels.

| Card | Value | Reference label | Conditional colour |
|---|---|---|---|
| Total MRR | `[Total MRR (£)]` | `[MRR MoM Label]` | Label coloured by `[KPI Colour - Higher Is Better]` |
| ARR | `[ARR (£)]` | "Run-rate, MRR × 12" (static) | – |
| NRR (TTM) | `[NRR % (TTM)]` | `[NRR Change vs 3M Ago (pts)]` | Value red < 100%, amber 100–105%, teal > 105% |
| Logo churn (rolling 3M) | `[Rolling 3-Month Churn Rate %]` | "avg monthly, last 3 months" | Red when above 1.5% |
| Active customers | `[Active Customers]` | "£x new MRR this month" from `[New MRR (£)]` | – |
| Revenue at risk | `[High-Risk Revenue at Risk (£)]` | `[High-Risk ARR at Risk (£)]` as "£x.xm ARR" | Always red. Click-through bookmark to Page 2 at-risk table |

### Visuals

| # | Visual | Fields | Tooltip | Notes |
|---|---|---|---|---|
| A | **Waterfall** | Category: `Bridge Steps[Step]` (sorted by `Sort`). Y: `[MRR Bridge Value]` | Step value, and as % of opening MRR | Increase = teal, decrease = red, total = navy. Responds to Month slicer **plus** a "Period" toggle (Month / Quarter / YTD via bookmarks) so the CFO can see the full-year bridge |
| B | **Line chart** | X: `dim_date[month_start]` (continuous). Y: `[NRR % (TTM)]`, `[GRR % (TTM)]` | NRR, GRR, base MRR 12m ago | Constant line at 100% (grey dashed), labelled "break-even retention". Small multiples by `dim_customers[tier]` is a toggle; Enterprise falling while Mid-Market holds is the story |
| C | **Stacked area** | X: `dim_date[month_start]`. Y: `[Total MRR (£)]`. Legend: `dim_customers[tier]` | MRR, MoM % | Tier colours: Enterprise navy, Mid-Market teal, SMB grey |
| D | **Clustered bar** | Y: `dim_customers[region]`. X: `[Total MRR (£)]` | NRR, logo churn, active customers | Sorted descending. Data labels in £k |
| E | **Table** | Rows: last 6 `month_label`. Columns: `[New MRR (£)]`, `[Expansion MRR (£)]`, `[Contraction MRR (£)]`, `[Churned MRR (£)]` | – | Compact (10 pt). Churned column font red. Gives the exact numbers behind the waterfall |

---

## Page 2 — Churn & Customer Health Diagnostics

**Audience:** VP Customer Success, account managers. **The question:** why are we losing customers, and who's next?

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Churn & Customer Health                                    Data to: Sep 2026 │
├──────────────────────────┬───────────────────────────────────────────────────┤
│ F. Churned MRR by reason │ G. Cohort logo retention heatmap (matrix)         │
│    (bar, sorted)         │    rows: signup quarter, cols: months 0-24        │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ H. Adoption vs resolution│ I. At-risk accounts (table, conditional format)   │
│    time (scatter, 1 dot  │    Risk band = High, sorted by renewal then MRR   │
│    = 1 account)          │                                                   │
└──────────────────────────┴───────────────────────────────────────────────────┘
```

| # | Visual | Fields | Tooltip | Notes |
|---|---|---|---|---|
| F | **Clustered bar** | Y: `fact_mrr_movements[churn_reason]`. X: `[Churned MRR (£)]` | Logos lost, avg MRR per lost logo | Visual filter: `movement_type = "Churn"`. Colour by `ref_churn_reason` group if imported (Controllable red, Commercial amber, Uncontrollable/Unknown grey). The "Not recorded" bar stays visible: it is a process problem in its own right |
| G | **Matrix** | Rows: `dim_customers[cohort_quarter]`. Columns: `fact_mrr_movements[months_since_signup]`. Values: `[Cohort Logo Retention %]` | Cohort size, starting MRR | Visual filters: `is_pre_history_account = False`, `months_since_signup` in 0, 3, 6, 9, 12, 15, 18, 21, 24. **Background colour scale** on the value: red 60% → amber 85% → teal 100%. Blank cells stay blank (cohort too young), not zero |
| H | **Scatter** | Details: `dim_customers[company_name]`. X: `[Median Resolution Time (hrs)]`. Y: `[Avg Feature Adoption %]`. Size: `[Total MRR (£)]`. Legend: `dim_customers[tier]` | Company, AM, MRR, P1/P2 breaches (`[High-Priority SLA Breaches]`), Avg CSAT | Visual filter: last 3 months on `dim_date`. Average lines on both axes splits the chart into quadrants; bottom-right (slow support, low adoption) is the danger zone; label it with a text box |
| I | **Table** | `account_health`: company_name, tier, account_manager, mrr_gbp, next_renewal_month, hp_breaches_90d, adoption_13w, adoption_trend_pts, avg_csat_180d, risk_score, risk_band | Full suggested next step (from `03_ad_hoc_investigation.sql` Q2 logic) | Filter: `risk_band = "High"`, default tier Enterprise. Conditional formatting: `risk_score` **data bars** (red); `hp_breaches_90d` background red when ≥ 2; `adoption_13w` font red < 35, amber < 50; `next_renewal_month` icon ⚠ when within 90 days. Sort: renewal date ascending. **Drill-through** to an account detail page (ticket list + weekly usage line) by right-clicking a row |

---

## Page 3 — Operational SLA & Support Efficiency

**Audience:** Head of Support, COO. **The question:** where is the support queue failing, and does it cost us renewals?

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Support SLA & Efficiency                                   Data to: Sep 2026 │
├────────────┬────────────┬────────────┬───────────────────────────────────────┤
│ SLA        │ P1/P2 SLA  │ Median     │ Avg CSAT       │ Open tickets       │
│ compliance │ compliance │ resolution │                │ past SLA           │
├────────────┴────────────┴────────────┴───────────────────────────────────────┤
│ J. Ticket volume vs SLA compliance (combo: columns + line), 24 months        │
├──────────────────────────────────────┬───────────────────────────────────────┤
│ K. Renewal rate by CSAT band         │ L. Bottleneck matrix                  │
│    (column + line)                   │    category × priority, breach %      │
│                                      ├───────────────────────────────────────┤
│                                      │ M. Hours over SLA by category (bar)   │
└──────────────────────────────────────┴───────────────────────────────────────┘
```

### KPI cards

| Card | Value | Reference label | Conditional colour |
|---|---|---|---|
| SLA compliance | `[SLA Compliance %]` | Same month last year | Red < 85%, amber 85–92%, teal ≥ 92% (the contractual target) |
| P1/P2 SLA compliance | `[SLA Compliance %]` with card filter `is_high_priority = True` | – | Same thresholds |
| Median resolution | `[Median Resolution Time (hrs)]` | – | – |
| Avg CSAT | `[Avg CSAT]` | – | Red < 3.5 |
| Open past SLA | `[Tickets]` filtered `is_open = True`, `sla_breached = True` | – | Red if > 0 |

### Visuals

| # | Visual | Fields | Tooltip | Notes |
|---|---|---|---|---|
| J | **Line and clustered column** | X: `dim_date[month_start]`. Columns: `[Tickets]` (grey). Line: `[SLA Compliance %]` (navy, secondary axis 60–100%) | Tickets, breaches, compliance, median hrs | Constant line at 92% target (red dashed) on the secondary axis. Annotate Mar 2025 with a text box: "Support hiring freeze". The gap between rising volume and falling compliance is the point |
| K | **Line and clustered column** | X: `fact_renewals[csat_band]`. Columns: `[Renewal Rate %]`. Line: count of renewals | Renewal outcome split (expanded / flat / downgraded / churned) | Sorted by band (labels are prefixed 1., 2., 3.). "No responses" placed last and coloured grey: no survey response tells you nothing |
| L | **Matrix** | Rows: `fact_support_tickets[category]` (with `owning_team` as parent level). Columns: `priority_code`. Values: `[SLA Breach %]` | Tickets, median hrs | Background colour scale white → red, centred on the 8% tolerance. Row subtotal shows category breach rate. Expand to owning team to show it's an Engineering-escalation problem, not a front-line one |
| M | **Clustered bar** | Y: `category`. X: sum of `hours_over_sla` | Breach %, P90 resolution hrs (add as measure if wanted) | Sorted descending. Shows where the late hours actually sit: Integration / API, Performance and Bug own about three quarters of them |

### Page-level filter

Exclude tickets with `sla_evaluable = False` from J and L only (open tickets still inside SLA would otherwise distort the rate). Volumes on J still count all tickets.

---

## Accessibility and polish checklist

- Alt text on every visual, describing the takeaway, not the chart type.
- No meaning carried by colour alone: risk band also appears as text; deltas carry ▲/▼.
- Tab order set top-left to bottom-right (Selection pane).
- Tooltips report pages for the scatter (H) and the at-risk table (I).
- Performance Analyzer: every visual under 500 ms on the full dataset. `High-Risk Revenue at Risk (£)` is the heaviest measure; keep it off visuals with many rows.
