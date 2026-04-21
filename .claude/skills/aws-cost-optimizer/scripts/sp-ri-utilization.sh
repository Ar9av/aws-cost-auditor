#!/usr/bin/env bash
#
# sp-ri-utilization.sh — Savings Plan and Reserved Instance utilization over
# the last 30 days. Uses 2 CE calls = $0.02.
#
# Usage: sp-ri-utilization.sh [--profile <p>] [--output-dir <path>] [--human]

set -euo pipefail

PROFILE=""
OUT_DIR="reports"
HUMAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    PROFILE="$2"; shift 2 ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --human)      HUMAN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-sp-ri-utilization.json"

ce() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --region us-east-1 --output json ce "$@"
  else
    aws --region us-east-1 --output json ce "$@"
  fi
}

today=$(date -u +%Y-%m-%d)
if date -u -v-30d +%Y-%m-%d >/dev/null 2>&1; then
  start=$(date -u -v-30d +%Y-%m-%d)
else
  start=$(date -u -d "30 days ago" +%Y-%m-%d)
fi

echo "[1/2] Savings Plans utilization..." >&2
sp=$(ce get-savings-plans-utilization \
  --time-period "Start=$start,End=$today" \
  --granularity MONTHLY 2>/dev/null || echo '{}')

echo "[2/2] Reservations utilization..." >&2
ri=$(ce get-reservation-utilization \
  --time-period "Start=$start,End=$today" \
  --granularity MONTHLY 2>/dev/null || echo '{}')

jq -n \
  --argjson sp "$sp" \
  --argjson ri "$ri" \
  --arg start "$start" --arg end "$today" \
  '{
    period: { start: $start, end: $end },
    savings_plans: {
      total_commitment: (($sp.Total.Utilization.TotalCommitment // "0") | tonumber),
      used_commitment:  (($sp.Total.Utilization.UsedCommitment  // "0") | tonumber),
      unused_commitment:(($sp.Total.Utilization.UnusedCommitment // "0") | tonumber),
      utilization_pct:  (($sp.Total.Utilization.UtilizationPercentage // "0") | tonumber),
      net_savings:      (($sp.Total.Savings.NetSavings // "0") | tonumber)
    },
    reservations: {
      total_actual_hours: (($ri.Total.TotalActualHours // "0") | tonumber),
      unused_hours:       (($ri.Total.UnusedHours // "0") | tonumber),
      utilization_pct:    (($ri.Total.UtilizationPercentage // "0") | tonumber),
      net_ri_savings:     (($ri.Total.NetRISavings // "0") | tonumber),
      amortized_cost:     (($ri.Total.AmortizedRecurringFee // "0") | tonumber)
    },
    meta: { ce_api_calls: 2, estimated_cost_usd: 0.02 }
  }' | tee "$OUT_JSON" >/dev/null

echo "Wrote $OUT_JSON" >&2

if [[ "$HUMAN" == "1" ]]; then
  jq -r '
    def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
    "# Savings Plan & Reserved Instance Utilization",
    "Period: \(.period.start) → \(.period.end)",
    "",
    "## Savings Plans",
    "- Utilization: \(.savings_plans.utilization_pct)%",
    "- Unused commitment: \(.savings_plans.unused_commitment | fmt)",
    "- Net savings: \(.savings_plans.net_savings | fmt)",
    "",
    "## Reserved Instances",
    "- Utilization: \(.reservations.utilization_pct)%",
    "- Unused hours: \(.reservations.unused_hours)",
    "- Net RI savings: \(.reservations.net_ri_savings | fmt)"
  ' "$OUT_JSON"
fi
