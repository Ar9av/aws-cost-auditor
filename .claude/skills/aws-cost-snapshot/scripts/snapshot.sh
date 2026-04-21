#!/usr/bin/env bash
#
# snapshot.sh — high-level AWS cost overview via Cost Explorer.
#
# Usage:
#   snapshot.sh [--profile <name>] [--metric <metric>]
#               [--forecast] [--by-account]
#               [--output-dir <path>] [--human]
#
# Defaults:
#   --metric UnblendedCost
#   --output-dir reports/
#
# Cost: ~$0.05-0.08 depending on flags (each CE call is $0.01).

set -euo pipefail

PROFILE=""
METRIC="UnblendedCost"
DO_FORECAST=0
DO_ACCOUNTS=0
OUT_DIR="reports"
HUMAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    PROFILE="$2"; shift 2 ;;
    --metric)     METRIC="$2"; shift 2 ;;
    --forecast)   DO_FORECAST=1; shift ;;
    --by-account) DO_ACCOUNTS=1; shift ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --human)      HUMAN=1; shift ;;
    -h|--help)    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-snapshot.json"

# CE requires us-east-1 regardless of where resources live.
ce() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --region us-east-1 --output json ce "$@"
  else
    aws --region us-east-1 --output json ce "$@"
  fi
}

# --- Date math (GNU vs BSD date) ---
today=$(date -u +%Y-%m-%d)
# First day of current month.
mtd_start=$(date -u +%Y-%m-01)
# First day of previous month.
if date -u -v-1m +%Y-%m >/dev/null 2>&1; then
  # BSD/macOS
  prev_month_start=$(date -u -v-1m +%Y-%m-01)
  prev_month_end_inclusive=$(date -u -v-1m +%Y-%m-%d -j -f "%Y-%m-%d" "$(date -u -v-1m +%Y-%m-01)" +%Y-%m-%d 2>/dev/null || date -u -v-1d -v1m +%Y-%m-%d)
  prev_month_end=$mtd_start
  sixty_ago=$(date -u -v-60d +%Y-%m-%d)
  forecast_start=$(date -u -v+1d +%Y-%m-%d)
  forecast_end=$(date -u -v+30d +%Y-%m-%d)
else
  # GNU/Linux
  prev_month_start=$(date -u -d "$(date -u +%Y-%m-01) -1 month" +%Y-%m-01)
  prev_month_end=$mtd_start
  sixty_ago=$(date -u -d "60 days ago" +%Y-%m-%d)
  forecast_start=$(date -u -d "tomorrow" +%Y-%m-%d)
  forecast_end=$(date -u -d "+30 days" +%Y-%m-%d)
fi

CALLS=0

# --- 1. Month-to-date total ---
echo "[1/5] Fetching month-to-date total..." >&2
mtd_raw=$(ce get-cost-and-usage \
  --time-period "Start=$mtd_start,End=$today" \
  --granularity MONTHLY \
  --metrics "$METRIC")
CALLS=$((CALLS + 1))
mtd_amount=$(jq -r ".ResultsByTime[0].Total.$METRIC.Amount // \"0\"" <<<"$mtd_raw")

# --- 2. Previous month total ---
echo "[2/5] Fetching previous month total..." >&2
prev_raw=$(ce get-cost-and-usage \
  --time-period "Start=$prev_month_start,End=$prev_month_end" \
  --granularity MONTHLY \
  --metrics "$METRIC")
CALLS=$((CALLS + 1))
prev_amount=$(jq -r ".ResultsByTime[0].Total.$METRIC.Amount // \"0\"" <<<"$prev_raw")

# --- 3. Top services this month ---
echo "[3/5] Fetching top services..." >&2
svc_raw=$(ce get-cost-and-usage \
  --time-period "Start=$mtd_start,End=$today" \
  --granularity MONTHLY \
  --metrics "$METRIC" \
  --group-by Type=DIMENSION,Key=SERVICE)
CALLS=$((CALLS + 1))

# --- 4. Top services previous month (for MoM delta) ---
echo "[4/5] Fetching previous-month services for MoM..." >&2
svc_prev_raw=$(ce get-cost-and-usage \
  --time-period "Start=$prev_month_start,End=$prev_month_end" \
  --granularity MONTHLY \
  --metrics "$METRIC" \
  --group-by Type=DIMENSION,Key=SERVICE)
CALLS=$((CALLS + 1))

# --- 5. 60-day daily series ---
echo "[5/5] Fetching 60-day daily series..." >&2
daily_raw=$(ce get-cost-and-usage \
  --time-period "Start=$sixty_ago,End=$today" \
  --granularity DAILY \
  --metrics "$METRIC")
CALLS=$((CALLS + 1))

# --- 6. (optional) 30-day forecast ---
forecast_json="null"
if [[ "$DO_FORECAST" == "1" ]]; then
  echo "[+] Fetching forecast..." >&2
  forecast_raw=$(ce get-cost-forecast \
    --time-period "Start=$forecast_start,End=$forecast_end" \
    --granularity MONTHLY \
    --metric "$METRIC" \
    --prediction-interval-level 80 || echo '{}')
  CALLS=$((CALLS + 1))
  forecast_json=$(jq '{
    amount: (.Total.Amount | tonumber? // 0),
    unit: .Total.Unit,
    confidence_interval: [
      (.ForecastResultsByTime[0].PredictionIntervalLowerBound | tonumber? // 0),
      (.ForecastResultsByTime[0].PredictionIntervalUpperBound | tonumber? // 0)
    ]
  }' <<<"$forecast_raw")
fi

# --- 7. (optional) Per linked account ---
accounts_json="null"
if [[ "$DO_ACCOUNTS" == "1" ]]; then
  echo "[+] Fetching per-account..." >&2
  acct_raw=$(ce get-cost-and-usage \
    --time-period "Start=$mtd_start,End=$today" \
    --granularity MONTHLY \
    --metrics "$METRIC" \
    --group-by Type=DIMENSION,Key=LINKED_ACCOUNT || echo '{}')
  CALLS=$((CALLS + 1))
  accounts_json=$(jq "[.ResultsByTime[0].Groups[]? | {
    account_id: .Keys[0],
    mtd: (.Metrics.$METRIC.Amount | tonumber)
  }] | sort_by(-.mtd)" <<<"$acct_raw")
fi

# --- Build top-services merged with prev-month ---
services_merged=$(jq -n \
  --argjson cur "$(jq "[.ResultsByTime[0].Groups[]? | {service: .Keys[0], amt: (.Metrics.$METRIC.Amount | tonumber)}]" <<<"$svc_raw")" \
  --argjson prev "$(jq "[.ResultsByTime[0].Groups[]? | {service: .Keys[0], amt: (.Metrics.$METRIC.Amount | tonumber)}]" <<<"$svc_prev_raw")" \
  '
  def prev_for(s): ($prev[] | select(.service == s) | .amt) // 0;
  [$cur[] | {
    service: .service,
    mtd: .amt,
    prev_month: prev_for(.service),
    mom_delta_pct: (if prev_for(.service) > 0 then ((.amt - prev_for(.service)) / prev_for(.service) * 100) else null end)
  }] | sort_by(-.mtd) | .[0:10]
  ')

# --- Daily series flattened ---
daily_series=$(jq "[.ResultsByTime[] | {
  date: .TimePeriod.Start,
  amount: (.Total.$METRIC.Amount | tonumber)
}]" <<<"$daily_raw")

# --- MoM pacing ---
mom_pacing=$(jq -n \
  --arg mtd "$mtd_amount" \
  --arg prev "$prev_amount" \
  --arg today "$today" \
  --arg mtd_start "$mtd_start" \
  '
  ($mtd | tonumber) as $m |
  ($prev | tonumber) as $p |
  (($today | split("-") | .[2] | tonumber) - 1) as $days |
  if $p > 0 and $days > 0 then
    ((($m / $days) * 30) / $p * 100 - 100)
  else null end
  ')

# --- Identity ---
if [[ -n "$PROFILE" ]]; then
  ident=$(aws --profile "$PROFILE" --region us-east-1 --output json sts get-caller-identity)
else
  ident=$(aws --region us-east-1 --output json sts get-caller-identity)
fi
ACCOUNT_ID=$(jq -r .Account <<<"$ident")

# --- Compose output ---
COST=$(awk "BEGIN {printf \"%.2f\", $CALLS * 0.01}")

jq -n \
  --arg account "$ACCOUNT_ID" \
  --arg metric "$METRIC" \
  --arg mtd_start "$mtd_start" \
  --arg today "$today" \
  --arg prev_start "$prev_month_start" \
  --arg prev_end "$prev_month_end" \
  --argjson mtd "$mtd_amount" \
  --argjson prev "$prev_amount" \
  --argjson mom "$mom_pacing" \
  --argjson services "$services_merged" \
  --argjson daily "$daily_series" \
  --argjson forecast "$forecast_json" \
  --argjson accounts "$accounts_json" \
  --argjson calls "$CALLS" \
  --arg cost "$COST" \
  '{
    account_id: $account,
    currency: "USD",
    metric: $metric,
    month_to_date: { amount: $mtd, period: { start: $mtd_start, end: $today } },
    previous_month: { amount: $prev, period: { start: $prev_start, end: $prev_end } },
    mom_pacing_pct: $mom,
    top_services: $services,
    daily_series_60d: $daily,
    forecast_next_30d: $forecast,
    by_account: $accounts,
    meta: {
      ce_api_calls: $calls,
      estimated_cost_usd: ($cost | tonumber),
      generated_at: (now | todate)
    }
  }' | tee "$OUT_JSON" >/dev/null

echo "Wrote $OUT_JSON  (CE calls: $CALLS, est. cost: \$$COST)" >&2

if [[ "$HUMAN" == "1" ]]; then
  bash "$(dirname "$0")/render-summary.sh" "$OUT_JSON"
else
  cat "$OUT_JSON"
fi
