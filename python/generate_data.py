"""
NorthStar Cloud Ltd - synthetic data generator
==============================================

Builds four relational CSV extracts that look like what you'd actually pull
out of a B2B SaaS company's CRM, billing system, helpdesk and product
telemetry:

    dim_customers.csv          one row per account (CRM)
    fact_subscriptions.csv     one row per account per billing month (billing)
    fact_support_tickets.csv   one row per support ticket (helpdesk)
    fact_product_usage.csv     one row per account per week (telemetry)

The data is simulated month by month so that cause and effect line up:

  * Every account carries a hidden "health" score (0-1).
  * Slow support (SLA breaches, especially on P1/P2 tickets) pushes health
    down; health drifts back towards the account's natural baseline otherwise.
  * Health drives product adoption, expansion, contraction and churn.
  * Annual-contract accounts can only churn or downgrade at their renewal
    month, which is how support pain turns into lost renewals.
  * From spring 2025 the support team loses capacity (hiring freeze), so
    resolution times stretch, SLA breaches rise and retention suffers.

The extracts are deliberately messy in the ways real extracts are messy:
duplicate rows from re-syncs, inconsistent casing, mixed date formats,
currency symbols in numeric fields, nulls, impossible values and a few
orphan/test records. Cleaning them is the job of sql/01_schema_and_cleaning.sql.

Usage:
    python python/generate_data.py                 # defaults
    python python/generate_data.py --seed 7 --out data/raw
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
START_MONTH = pd.Timestamp("2023-10-01")   # first month of billing history
END_MONTH = pd.Timestamp("2026-09-01")     # last complete month
SNAPSHOT_TS = pd.Timestamp("2026-09-30 23:59:59")  # extract taken here

N_OPENING_ACCOUNTS = 520                    # live accounts at START_MONTH
NEW_ACCOUNTS_PER_MONTH = 30                 # average, before seasonality

TIERS = ["SMB", "Mid-Market", "Enterprise"]
TIER_MIX_NEW = [0.60, 0.30, 0.10]

INDUSTRIES = ["Logistics", "Healthcare", "Retail", "Financial Services",
              "Manufacturing", "Professional Services", "Education",
              "Public Sector"]
INDUSTRY_WEIGHTS = [0.16, 0.12, 0.15, 0.13, 0.14, 0.15, 0.07, 0.08]

REGIONS = ["London & South East", "North West", "Midlands",
           "Yorkshire & North East", "Scotland", "South West & Wales",
           "Ireland"]
REGION_WEIGHTS = [0.34, 0.16, 0.14, 0.11, 0.10, 0.09, 0.06]

ACCOUNT_MANAGERS = {
    "Enterprise": ["Priya Raman", "Tom Whitfield", "Grace Okafor"],
    "Mid-Market": ["Daniel Hughes", "Aisha Patel", "Callum Reid",
                   "Hannah Doyle"],
    "SMB": ["Liam Carter", "Sophie Turner", "Owen Price", "Megan Shaw",
            "Ravi Mehta"],
}

# Monthly MRR ranges (GBP) at signup
MRR_RANGE = {"SMB": (99, 750), "Mid-Market": (800, 3_800),
             "Enterprise": (4_500, 24_000)}
ANNUAL_SHARE = {"SMB": 0.30, "Mid-Market": 0.65, "Enterprise": 0.92}

# Support model
SLA_HOURS = {"P1": 8, "P2": 24, "P3": 72, "P4": 120}
MEDIAN_RES_HOURS = {"P1": 2.6, "P2": 7.5, "P3": 22.0, "P4": 40.0}
PRIORITY_MIX = {
    "Enterprise": [0.08, 0.27, 0.45, 0.20],
    "Mid-Market": [0.05, 0.22, 0.48, 0.25],
    "SMB": [0.03, 0.17, 0.50, 0.30],
}
TICKET_RATE = {"SMB": 0.35, "Mid-Market": 0.95, "Enterprise": 2.8}
CATEGORIES = ["Integration / API", "Performance", "Bug", "Billing",
              "Access & SSO", "Onboarding", "Data Import", "Feature Request"]
CATEGORY_WEIGHTS = {
    "Enterprise": [0.24, 0.15, 0.17, 0.07, 0.12, 0.08, 0.10, 0.07],
    "Mid-Market": [0.17, 0.12, 0.19, 0.11, 0.10, 0.12, 0.11, 0.08],
    "SMB": [0.09, 0.10, 0.20, 0.19, 0.09, 0.17, 0.08, 0.08],
}
# Resolution-time multiplier: integration and performance work needs
# engineering escalation, so it is the slowest queue.
CATEGORY_FACTOR = {"Integration / API": 1.65, "Performance": 1.40,
                   "Bug": 1.20, "Billing": 0.70, "Access & SSO": 0.60,
                   "Onboarding": 0.90, "Data Import": 1.10,
                   "Feature Request": 1.15}

CHURN_REASONS = ["Poor support experience", "Low product adoption",
                 "Price / budget cuts", "Moved to competitor",
                 "Business closed / acquired", "Consolidated tooling"]

NAME_A = ["Northgate", "Pennine", "Brightwater", "Castlefield", "Harbour",
          "Redbrick", "Ashford", "Kingsway", "Meridian", "Oakridge",
          "Thames", "Sterling", "Clyde", "Mersey", "Wessex", "Highland",
          "Lowther", "Fenwick", "Calder", "Severn", "Albion", "Granite",
          "Bluebell", "Ironbridge", "Moorland", "Riverside", "Cobalt",
          "Saxon", "Westmoor", "Heathrow", "Quayside", "Lantern", "Beacon",
          "Holloway", "Ember", "Tamar", "Avon", "Peak", "Falcon", "Orchard"]
NAME_B = ["Logistics", "Health", "Retail", "Capital", "Engineering",
          "Consulting", "Freight", "Care", "Foods", "Systems", "Partners",
          "Distribution", "Manufacturing", "Learning", "Housing", "Energy",
          "Analytics", "Supplies", "Medical", "Advisory"]
NAME_C = ["Ltd", "Ltd", "Ltd", "Group", "plc", "LLP", "Holdings", "Ltd"]


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def month_range(start: pd.Timestamp, end: pd.Timestamp) -> list[pd.Timestamp]:
    return list(pd.date_range(start, end, freq="MS"))


def support_capacity_factor(month: pd.Timestamp) -> float:
    """>1 means tickets take longer. Hiring freeze bites from Mar 2025,
    peaks over summer 2025, and only partly recovers in 2026."""
    m = (month.year - 2025) * 12 + month.month   # 3 == Mar 2025
    if m < 3:
        return 1.0
    if m <= 9:                                    # ramp Mar -> Sep 2025
        return 1.0 + 0.75 * (m - 2) / 7
    if m <= 15:                                   # partial recovery to Mar 26
        return 1.75 - 0.25 * (m - 9) / 6
    return 1.50


def ticket_seasonality(month: pd.Timestamp) -> float:
    # January (year-start config changes) and September (release cycle)
    # are busy; August and December are quiet.
    return {1: 1.25, 2: 1.05, 3: 1.05, 4: 0.95, 5: 1.0, 6: 1.0, 7: 0.95,
            8: 0.80, 9: 1.20, 10: 1.10, 11: 1.0, 12: 0.75}[month.month]


def signup_seasonality(month: pd.Timestamp) -> float:
    # Q1 budget releases and a September push; summer and Christmas dip.
    return {1: 1.30, 2: 1.15, 3: 1.25, 4: 0.95, 5: 0.95, 6: 0.90,
            7: 0.80, 8: 0.70, 9: 1.20, 10: 1.10, 11: 1.0, 12: 0.65}[month.month]


@dataclass
class Account:
    account_id: str
    company_name: str
    industry: str
    region: str
    tier: str
    signup_date: pd.Timestamp
    account_manager: str
    plan_type: str
    baseline_health: float
    complexity: float           # some customers' setups are just harder
    mrr: float
    health: float
    active: bool = True
    churned_at: pd.Timestamp | None = None
    hp_breach_history: list[int] = field(default_factory=list)  # per month


# --------------------------------------------------------------------------
# Generator
# --------------------------------------------------------------------------
class NorthStarGenerator:
    def __init__(self, seed: int = 42):
        self.rng = np.random.default_rng(seed)
        self.accounts: list[Account] = []
        self.sub_rows: list[dict] = []
        self.ticket_rows: list[dict] = []
        self.usage_rows: list[dict] = []
        self._next_account = 10001
        self._used_names: set[str] = set()

    # ---- account creation ------------------------------------------------
    def _company_name(self) -> str:
        r = self.rng
        for _ in range(50):
            name = f"{r.choice(NAME_A)} {r.choice(NAME_B)} {r.choice(NAME_C)}"
            if name not in self._used_names:
                self._used_names.add(name)
                return name
        name = f"{r.choice(NAME_A)} {r.choice(NAME_B)} {self._next_account} Ltd"
        self._used_names.add(name)
        return name

    def _new_account(self, signup_date: pd.Timestamp, tier: str) -> Account:
        r = self.rng
        lo, hi = MRR_RANGE[tier]
        # log-uniform so most accounts sit at the lower end of each band
        mrr = float(np.exp(r.uniform(np.log(lo), np.log(hi))))
        mrr = round(mrr / 5) * 5
        baseline = float(np.clip(r.beta(7, 3), 0.25, 0.97))
        acc = Account(
            account_id=f"NSC-{self._next_account}",
            company_name=self._company_name(),
            industry=r.choice(INDUSTRIES, p=INDUSTRY_WEIGHTS),
            region=r.choice(REGIONS, p=REGION_WEIGHTS),
            tier=tier,
            signup_date=signup_date,
            account_manager=r.choice(ACCOUNT_MANAGERS[tier]),
            plan_type="Annual" if r.random() < ANNUAL_SHARE[tier] else "Monthly",
            baseline_health=baseline,
            complexity=float(np.exp(r.normal(0, 0.22))),
            mrr=mrr,
            health=float(np.clip(baseline + r.normal(0, 0.05), 0.05, 0.98)),
        )
        self._next_account += 1
        self.accounts.append(acc)
        return acc

    def _seed_opening_book(self) -> None:
        """Accounts that were already customers before the history starts."""
        r = self.rng
        # Opening book is a little more enterprise-heavy (survivors).
        tiers = r.choice(TIERS, size=N_OPENING_ACCOUNTS, p=[0.55, 0.32, 0.13])
        for tier in tiers:
            days_before = int(r.integers(30, 365 * 4))
            signup = (START_MONTH - pd.Timedelta(days=days_before)).normalize()
            acc = self._new_account(signup, tier)
            # older accounts have usually grown a bit
            acc.mrr = round(acc.mrr * (1 + min(days_before / 365, 3) * 0.06) / 5) * 5

    @staticmethod
    def _is_renewal_month(acc: Account, month: pd.Timestamp) -> bool:
        if acc.plan_type != "Annual":
            return True    # monthly plans "renew" every month
        months = (month.year - acc.signup_date.year) * 12 + \
                 (month.month - acc.signup_date.month)
        return months > 0 and months % 12 == 0

    # ---- monthly simulation ---------------------------------------------
    def _simulate_tickets(self, acc: Account, month: pd.Timestamp) -> tuple[int, int]:
        """Create this month's tickets. Returns (hp_breaches, other_breaches)."""
        r = self.rng
        rate = TICKET_RATE[acc.tier] * (1 + 0.9 * (1 - acc.health)) \
            * ticket_seasonality(month)
        n = r.poisson(rate)
        cap = support_capacity_factor(month)
        days_in_month = month.days_in_month
        hp_b = other_b = 0
        for _ in range(n):
            pr = r.choice(["P1", "P2", "P3", "P4"], p=PRIORITY_MIX[acc.tier])
            cat = r.choice(CATEGORIES, p=CATEGORY_WEIGHTS[acc.tier])
            # created mostly in UK working hours
            day = int(r.integers(0, days_in_month))
            hour = int(np.clip(r.normal(12.5, 2.8), 0, 23))
            created = month + pd.Timedelta(days=day, hours=hour,
                                           minutes=int(r.integers(0, 60)))
            median = MEDIAN_RES_HOURS[pr] * CATEGORY_FACTOR[cat] * cap \
                * acc.complexity
            hours = float(np.exp(np.log(median) + r.normal(0, 0.62)))
            resolved = created + pd.Timedelta(hours=hours)
            breached = hours > SLA_HOURS[pr]
            if breached:
                if pr in ("P1", "P2"):
                    hp_b += 1
                else:
                    other_b += 1

            csat = None
            if resolved <= SNAPSHOT_TS and r.random() < 0.46:
                ratio = hours / SLA_HOURS[pr]
                if breached:
                    p = [0.28, 0.30, 0.24, 0.12, 0.06]
                elif ratio > 0.6:
                    p = [0.05, 0.10, 0.25, 0.35, 0.25]
                else:
                    p = [0.02, 0.04, 0.12, 0.34, 0.48]
                csat = int(r.choice([1, 2, 3, 4, 5], p=p))
                # customers who are already unhappy with the product mark
                # support down too - CSAT carries general sentiment
                if acc.health < 0.50 and r.random() < 0.55:
                    csat = max(1, csat - int(r.integers(1, 3)))

            self.ticket_rows.append({
                "ticket_id": f"TCK-{len(self.ticket_rows) + 100001}",
                "account_id": acc.account_id,
                "created_at": created,
                "resolved_at": resolved if resolved <= SNAPSHOT_TS else pd.NaT,
                "priority": pr,
                "category": cat,
                "csat_score": csat,
            })
        return hp_b, other_b

    def _simulate_usage(self, acc: Account, month: pd.Timestamp) -> None:
        r = self.rng
        seats = max(3, int(acc.mrr / {"SMB": 28, "Mid-Market": 32,
                                      "Enterprise": 38}[acc.tier]))
        api_scale = {"SMB": 120, "Mid-Market": 650, "Enterprise": 2_400}[acc.tier]
        mondays = pd.date_range(month, month + pd.offsets.MonthEnd(0),
                                freq="W-MON")
        for wk in mondays:
            # week-to-week noise, plus a summer and Christmas dip
            seasonal = 0.85 if wk.month == 8 or (wk.month == 12 and wk.day > 18) else 1.0
            util = np.clip(0.30 + 0.60 * acc.health + r.normal(0, 0.05), 0.05, 1.0)
            users = max(1, int(round(seats * util * seasonal)))
            api = int(users * api_scale / seats * r.lognormal(0, 0.35)
                      * (0.6 + acc.health))
            adoption = float(np.clip(12 + 78 * acc.health + r.normal(0, 4), 2, 99))
            self.usage_rows.append({
                "usage_id": None,  # assigned later
                "account_id": acc.account_id,
                "activity_date": wk.date(),
                "active_users": users,
                "api_calls": api,
                "feature_adoption_pct": round(adoption, 1),
            })

    def _churn_probability(self, acc: Account, month: pd.Timestamp) -> float:
        hp_last_q = sum(acc.hp_breach_history[-3:])
        hp_last_2q = sum(acc.hp_breach_history[-6:])
        base = {"SMB": -3.85, "Mid-Market": -4.7, "Enterprise": -5.45}[acc.tier]
        logit = base + 3.0 * (0.62 - acc.health) + 0.38 * min(hp_last_q, 6) \
            + 0.12 * min(hp_last_2q, 10)
        p_month = 1 / (1 + np.exp(-logit))
        if acc.plan_type == "Annual":
            # one decision a year, so it carries a year's worth of risk
            return float(1 - (1 - p_month) ** 10)
        return float(p_month)

    def _churn_reason(self, acc: Account) -> str:
        hp_last_2q = sum(acc.hp_breach_history[-6:])
        w = np.array([0.15 + 2.2 * min(hp_last_2q, 5),          # support
                      0.4 + 6.0 * max(0.0, 0.50 - acc.health),  # adoption
                      1.4, 1.0, 0.5, 0.7])
        return str(self.rng.choice(CHURN_REASONS, p=w / w.sum()))

    def _step_account(self, acc: Account, month: pd.Timestamp, idx: int) -> None:
        r = self.rng
        renewal = self._is_renewal_month(acc, month)
        new_this_month = acc.signup_date >= month and \
            acc.signup_date < month + pd.offsets.MonthBegin(1)

        # 1) commercial decision, made on the experience *up to* this month
        #    (renewal for annual plans, every month for monthly plans)
        if renewal and not new_this_month and r.random() < self._churn_probability(acc, month):
            acc.active = False
            acc.churned_at = month
            self.sub_rows.append({
                "account_id": acc.account_id, "billing_month": month.date(),
                "mrr_gbp": 0.0, "plan_type": acc.plan_type,
                "status": "Churned", "churn_reason": self._churn_reason(acc)})
            return

        if not new_this_month:
            if acc.plan_type == "Annual":
                if renewal:
                    if acc.health > 0.58 and r.random() < 0.60:
                        acc.mrr *= 1 + r.uniform(0.10, 0.40)    # upsell
                    elif acc.health < 0.48 and r.random() < 0.40:
                        acc.mrr *= 1 - r.uniform(0.10, 0.35)    # seat cut
                    else:
                        acc.mrr *= 1.04                          # CPI uplift
                elif acc.health > 0.62 and r.random() < 0.02:
                    acc.mrr *= 1 + r.uniform(0.05, 0.15)        # mid-term seats
            else:
                if acc.health > 0.60 and r.random() < 0.055:
                    acc.mrr *= 1 + r.uniform(0.10, 0.50)
                elif acc.health < 0.48 and r.random() < 0.06:
                    acc.mrr *= 1 - r.uniform(0.10, 0.40)
            lo = MRR_RANGE[acc.tier][0] * 0.6
            acc.mrr = max(lo, round(acc.mrr / 5) * 5)

        self.sub_rows.append({
            "account_id": acc.account_id, "billing_month": month.date(),
            "mrr_gbp": float(acc.mrr), "plan_type": acc.plan_type,
            "status": "Active", "churn_reason": None})

        # 2) this month's support experience moves health; the damage from a
        #    badly handled P1/P2 lingers for months, it doesn't reset
        hp_b, other_b = self._simulate_tickets(acc, month)
        acc.hp_breach_history.append(hp_b)
        acc.health += 0.10 * (acc.baseline_health - acc.health) \
            + r.normal(0, 0.03) - 0.065 * hp_b - 0.02 * other_b
        acc.health = float(np.clip(acc.health, 0.02, 0.98))

        # 3) product usage for the month
        self._simulate_usage(acc, month)

    def _maybe_reactivate(self, acc: Account, month: pd.Timestamp) -> bool:
        """A handful of monthly-plan SMBs come back after a gap."""
        if acc.plan_type != "Monthly" or acc.tier != "SMB" or acc.churned_at is None:
            return False
        gap = (month.year - acc.churned_at.year) * 12 + month.month - acc.churned_at.month
        if gap >= 3 and self.rng.random() < 0.012:
            acc.active = True
            acc.health = float(np.clip(acc.baseline_health, 0.4, 0.9))
            acc.hp_breach_history = []
            acc.churned_at = None
            return True
        return False

    def run(self) -> None:
        self._seed_opening_book()
        r = self.rng
        months = month_range(START_MONTH, END_MONTH)
        for idx, month in enumerate(months):
            # new logos (momentum slows in 2026: weaker pipeline)
            growth = 1.0 if month.year < 2026 else 0.85
            n_new = r.poisson(NEW_ACCOUNTS_PER_MONTH * signup_seasonality(month) * growth)
            for tier in r.choice(TIERS, size=n_new, p=TIER_MIX_NEW):
                day = int(r.integers(0, month.days_in_month))
                self._new_account(month + pd.Timedelta(days=day), tier)

            for acc in self.accounts:
                if acc.signup_date >= month + pd.offsets.MonthBegin(1):
                    continue
                if not acc.active:
                    if not self._maybe_reactivate(acc, month):
                        continue
                self._step_account(acc, month, idx)

    # ---- output ----------------------------------------------------------
    def frames(self) -> dict[str, pd.DataFrame]:
        customers = pd.DataFrame([{
            "account_id": a.account_id, "company_name": a.company_name,
            "industry": a.industry, "region": a.region, "tier": a.tier,
            "signup_date": a.signup_date.date(),
            "account_manager": a.account_manager} for a in self.accounts])
        subs = pd.DataFrame(self.sub_rows)
        subs.insert(0, "sub_id", [f"SUB-{i:07d}" for i in range(1, len(subs) + 1)])
        tickets = pd.DataFrame(self.ticket_rows)
        usage = pd.DataFrame(self.usage_rows)
        usage["usage_id"] = [f"USG-{i:07d}" for i in range(1, len(usage) + 1)]
        return {"dim_customers": customers, "fact_subscriptions": subs,
                "fact_support_tickets": tickets, "fact_product_usage": usage}


# --------------------------------------------------------------------------
# Dirty-data injection: the stuff you find in real extracts
# --------------------------------------------------------------------------
def _sample_idx(rng, df: pd.DataFrame, share: float) -> np.ndarray:
    k = max(1, int(len(df) * share))
    return rng.choice(df.index.to_numpy(), size=k, replace=False)


def make_messy(frames: dict[str, pd.DataFrame], seed: int) -> dict[str, pd.DataFrame]:
    rng = np.random.default_rng(seed + 1)
    out = {}

    # ---- dim_customers (CRM) ----
    c = frames["dim_customers"].copy()
    c["signup_date"] = pd.to_datetime(c["signup_date"]).dt.strftime("%Y-%m-%d")
    idx = _sample_idx(rng, c, 0.07)                       # UK-style dates
    c.loc[idx, "signup_date"] = pd.to_datetime(c.loc[idx, "signup_date"]).dt.strftime("%d/%m/%Y")
    c.loc[_sample_idx(rng, c, 0.01), "signup_date"] = None
    c.loc[_sample_idx(rng, c, 0.06), "tier"] = c["tier"].str.upper()
    c.loc[_sample_idx(rng, c, 0.04), "tier"] = c["tier"].str.lower() + " "
    c.loc[_sample_idx(rng, c, 0.05), "region"] = c["region"].str.lower()
    c.loc[_sample_idx(rng, c, 0.05), "industry"] = " " + c["industry"].str.upper()
    c.loc[_sample_idx(rng, c, 0.02), "industry"] = None
    c.loc[_sample_idx(rng, c, 0.03), "account_manager"] = None
    c.loc[_sample_idx(rng, c, 0.04), "company_name"] = c["company_name"] + "  "
    # duplicate CRM records: same account, one copy less complete
    dup = c.loc[_sample_idx(rng, c, 0.015)].copy()
    dup["account_manager"] = None
    dup["tier"] = dup["tier"].str.lower()
    # internal test accounts that should never reach reporting
    tests = pd.DataFrame([{
        "account_id": f"NSC-9{i:04d}", "company_name": f"TEST ACCOUNT {i} - DO NOT USE",
        "industry": None, "region": "London & South East", "tier": "Enterprise",
        "signup_date": "2024-01-01", "account_manager": "Internal QA"} for i in range(1, 4)])
    c = pd.concat([c, dup, tests], ignore_index=True).sample(frac=1, random_state=seed)
    out["dim_customers"] = c

    # ---- fact_subscriptions (billing) ----
    s = frames["fact_subscriptions"].copy()
    s["mrr_gbp"] = s["mrr_gbp"].map(lambda v: f"{v:.2f}")
    idx = _sample_idx(rng, s, 0.03)                      # currency-formatted
    s.loc[idx, "mrr_gbp"] = s.loc[idx, "mrr_gbp"].map(lambda v: f"£{float(v):,.2f}")
    active_idx = s.index[(s["status"] == "Active")]
    s.loc[rng.choice(active_idx, size=int(len(s) * 0.004), replace=False), "mrr_gbp"] = None
    s.loc[_sample_idx(rng, s, 0.05), "status"] = s["status"].str.upper()
    s.loc[_sample_idx(rng, s, 0.04), "status"] = " " + s["status"].str.lower()
    s.loc[_sample_idx(rng, s, 0.03), "plan_type"] = s["plan_type"].str.lower()
    churn_idx = s.index[s["status"].str.strip().str.lower() == "churned"]
    s.loc[rng.choice(churn_idx, size=int(len(churn_idx) * 0.08), replace=False), "churn_reason"] = None
    sel = rng.choice(churn_idx, size=int(len(churn_idx) * 0.10), replace=False)
    s.loc[sel, "churn_reason"] = s.loc[sel, "churn_reason"].str.lower()
    # billing re-sync duplicates: new sub_id, same account-month
    dup = s.loc[_sample_idx(rng, s, 0.012)].copy()
    dup["sub_id"] = [f"SUB-R{i:06d}" for i in range(len(dup))]
    # orphan rows for the test accounts
    orphans = pd.DataFrame([{
        "sub_id": f"SUB-T{i:05d}", "account_id": "NSC-90001",
        "billing_month": d.date(), "mrr_gbp": "0.00", "plan_type": "Annual",
        "status": "Active", "churn_reason": None}
        for i, d in enumerate(month_range(pd.Timestamp("2024-01-01"), pd.Timestamp("2024-06-01")))])
    s = pd.concat([s, dup, orphans], ignore_index=True)
    out["fact_subscriptions"] = s.sort_values(["billing_month", "account_id"])

    # ---- fact_support_tickets (helpdesk) ----
    t = frames["fact_support_tickets"].copy()
    t["created_at"] = pd.to_datetime(t["created_at"]).dt.strftime("%Y-%m-%d %H:%M:%S")
    t["resolved_at"] = pd.to_datetime(t["resolved_at"]).dt.strftime("%Y-%m-%d %H:%M:%S")
    pmap = {"P1": ["P1 - Critical", "critical", "P1", "Critical "],
            "P2": ["P2 - High", "high", "P2", "HIGH"],
            "P3": ["P3 - Medium", "medium", "P3", "Medium"],
            "P4": ["P4 - Low", "low", "P4", "LOW "]}
    t["priority"] = [rng.choice(pmap[p], p=[0.70, 0.12, 0.10, 0.08]) for p in t["priority"]]
    idx = _sample_idx(rng, t, 0.06)
    t.loc[idx, "category"] = t.loc[idx, "category"].str.lower()
    idx = _sample_idx(rng, t, 0.03)
    t.loc[idx, "category"] = t.loc[idx, "category"].str.replace(" / ", "/").str.replace(" & ", "&")
    # bad clock data: resolved before created
    resolved = t.index[t["resolved_at"].notna()]
    bad = rng.choice(resolved, size=int(len(t) * 0.003), replace=False)
    t.loc[bad, "resolved_at"] = (pd.to_datetime(t.loc[bad, "created_at"])
                                 - pd.Timedelta(hours=3)).dt.strftime("%Y-%m-%d %H:%M:%S")
    rated = t.index[t["csat_score"].notna()]
    t.loc[rng.choice(rated, size=int(len(rated) * 0.004), replace=False), "csat_score"] = 0
    t["csat_score"] = t["csat_score"].astype("Int64")
    # duplicate ticket logs: webhook fired twice; some copies captured before
    # the ticket was closed so resolved_at is still empty
    dup = t.loc[_sample_idx(rng, t, 0.02)].copy()
    half = dup.sample(frac=0.5, random_state=seed).index
    dup.loc[half, "resolved_at"] = None
    dup.loc[half, "csat_score"] = pd.NA
    t = pd.concat([t, dup], ignore_index=True).sort_values("created_at")
    out["fact_support_tickets"] = t

    # ---- fact_product_usage (telemetry) ----
    u = frames["fact_product_usage"].copy()
    u.loc[_sample_idx(rng, u, 0.003), "api_calls"] = -1          # collector bug
    u.loc[_sample_idx(rng, u, 0.005), "active_users"] = None
    idx = _sample_idx(rng, u, 0.02)                               # 0-1 scale
    u.loc[idx, "feature_adoption_pct"] = (u.loc[idx, "feature_adoption_pct"] / 100).round(3)
    u["active_users"] = u["active_users"].astype("Int64")
    dup = u.loc[_sample_idx(rng, u, 0.015)].copy()
    dup["usage_id"] = [f"USG-D{i:06d}" for i in range(len(dup))]
    u = pd.concat([u, dup], ignore_index=True).sort_values(["activity_date", "account_id"])
    out["fact_product_usage"] = u
    return out


# --------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out", type=Path,
                        default=Path(__file__).resolve().parents[1] / "data" / "raw")
    args = parser.parse_args()

    gen = NorthStarGenerator(seed=args.seed)
    gen.run()
    messy = make_messy(gen.frames(), seed=args.seed)

    args.out.mkdir(parents=True, exist_ok=True)
    for name, df in messy.items():
        path = args.out / f"{name}.csv"
        df.to_csv(path, index=False)
        print(f"  {name:<24} {len(df):>8,} rows  ->  {path}")


if __name__ == "__main__":
    main()
