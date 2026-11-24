#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# NorthStar Cloud analytics - rebuild everything from scratch
#
#   1. generate the raw CSV extracts           (python)
#   2. land, clean and model them in Postgres  (sql/00 -> 02)
#   3. run the stakeholder investigation       (sql/03, output saved to docs/)
#   4. export every mart view to CSV           (for Power BI without Postgres)
#
# Uses the standard libpq environment variables, so point it at any server:
#   PGHOST=localhost PGUSER=postgres PGDATABASE=northstar ./scripts/run_pipeline.sh
# ----------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."
export PGDATABASE="${PGDATABASE:-northstar}"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
PSQL="psql -X -q -v ON_ERROR_STOP=1"

echo "==> 1/4  Generating synthetic extracts"
python3 python/generate_data.py --seed "${SEED:-42}"

echo "==> 2/4  Building warehouse in database '${PGDATABASE}'"
if ! psql -X -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '${PGDATABASE}'" | grep -q 1; then
    createdb "${PGDATABASE}"
fi
$PSQL -f sql/00_load_raw.sql              > /dev/null
$PSQL -f sql/01_schema_and_cleaning.sql   > docs/output_data_quality_report.txt
$PSQL -f sql/02_business_logic_views.sql  > /dev/null

echo "==> 3/4  Running ad hoc investigation"
$PSQL -f sql/03_ad_hoc_investigation.sql > docs/output_ad_hoc_investigation.txt

echo "==> 4/4  Exporting mart views to data/marts/"
mkdir -p data/marts
for view in dim_date dim_customers fact_mrr_movements fact_support_tickets \
            fact_product_usage fact_renewals v_account_health \
            v_mrr_bridge_monthly v_nrr_monthly v_support_sla_monthly; do
    $PSQL -c "\copy (SELECT * FROM mart.${view}) TO 'data/marts/${view}.csv' WITH (FORMAT csv, HEADER true)"
done

# Reconciliation guard: the MRR bridge must balance to the penny every month
bad=$(psql -X -Atc "SELECT COUNT(*) FROM mart.v_mrr_bridge_monthly WHERE bridge_check_gbp <> 0")
if [ "$bad" != "0" ]; then
    echo "!! MRR bridge does not reconcile in ${bad} month(s)" >&2
    exit 1
fi
echo "Done. Bridge reconciles in every month. Outputs in docs/ and data/marts/."
