# Business context

## The company

**NorthStar Cloud Ltd** is a fictional Manchester-based B2B SaaS company. Its product, *NorthStar Ops*, is a workflow and field-operations platform used by UK and Irish organisations in logistics, healthcare, retail, manufacturing, financial and professional services, education and the public sector.

| | |
|---|---|
| Customers (Sep 2026) | 1,179 live accounts: 133 Enterprise, 405 Mid-Market, 641 SMB |
| Revenue | £3.22m MRR, £38.6m ARR run-rate |
| Contracts | Enterprise mostly annual, SMB mostly monthly. Annual contracts renew on the signup anniversary with a standard 4% CPI uplift |
| Revenue concentration | Enterprise is 11% of customers and 57% of MRR |
| Support model | 24×7 desk. Tier 1 handles billing and access; Tier 2 handles data imports; Integration/API, Performance and Bug tickets escalate to Engineering |
| SLA policy (resolution) | P1 Critical 8h · P2 High 24h · P3 Medium 72h · P4 Low 120h. Contractual target: 92% within SLA |

### What happened

Through 2024 NorthStar grew quickly and retained well: trailing-12-month net revenue retention sat above 103%, Enterprise above 105%, and 93–94% of tickets were resolved inside SLA.

In **March 2025**, as part of a cost programme, support hiring was frozen and two senior engineers were moved off the escalation rota onto a platform rebuild. Nobody connected that decision to revenue at the time. Headline MRR kept rising, because new-logo sales were still strong, so the board pack looked fine.

By early 2026 the Customer Success team was flagging "difficult renewals", Finance noticed NRR had dipped below 100%, and the Head of Support was asking for headcount without a revenue case to back it. Each team had its own spreadsheet and its own version of the truth.

This project is the analysis an incoming BI lead would build to settle the argument with one set of numbers.

## Three business pain points

1. **Rising Enterprise churn.** Annualised Enterprise logo churn went from 5.4% (Apr 2024–Mar 2025) to 15.6% (Oct 2025–Sep 2026). Enterprise is where the money is, so each loss hurts: churned MRR over the last 12 months is three times the figure a year earlier (£429k vs £143k).

2. **Declining net revenue retention.** Company NRR fell from 104.1% (Mar 2025) to 94.9% (Sep 2026). Enterprise NRR fell from 105.0% to 88.5%. Below 100% means the existing customer base is shrinking, and growth now depends entirely on new sales, which are themselves slowing.

3. **SLA breaches hitting renewals.** SLA compliance dropped from about 93% to 78% after the freeze and has only recovered to 82.5%, still well short of the 92% target. The open question was whether this actually costs renewals, or whether customers grumble and stay anyway.

## Five executive questions the dashboard answers

| # | Question | Asked by | Answered in |
|---|---|---|---|
| 1 | **Where is our MRR growth coming from, and how much of it are we giving back?** New logos vs expansion vs churn, and how the mix has shifted since 2024 | CFO | Page 1: MRR bridge, movement table. `mart.v_mrr_bridge_monthly` |
| 2 | **Why has NRR fallen below 100%, and is it every segment or a few?** | CEO / CRO | Page 1: NRR trend by tier. `mart.v_nrr_monthly`, `03` Q1 cohort retention |
| 3 | **Do support SLA breaches actually cause churn, and how much ARR is exposed right now?** | CFO / Head of Support | Page 3: renewal rate by CSAT. `03` Q3 breach-to-churn analysis |
| 4 | **Which Enterprise accounts should Customer Success call before their next renewal, and what should they say?** | VP Customer Success | Page 2: at-risk accounts table. `03` Q2 call list |
| 5 | **Where exactly is the support queue failing, and what is the fastest fix?** | Head of Support / COO | Page 3: bottleneck matrix, hours over SLA. `03` Q4 |

## What this project is not

- It isn't real company data. The data is simulated (see `python/generate_data.py`) with the relationships described above built in, so the analysis has something real to find. The interesting part is the method: cleaning, metric definitions, the reconciled bridge, and turning a correlation into a costed recommendation.
- It doesn't prove causation. The breach-to-churn analysis is a leading-indicator study with a clean look-ahead window. It shows that accounts with repeated P1/P2 breaches churn far more often afterwards. In a real business I'd back it up with exit interviews and a controlled routing pilot before claiming the full ARR figure.
