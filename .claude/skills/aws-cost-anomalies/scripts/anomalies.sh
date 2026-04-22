#!/usr/bin/env bash
#
# anomalies.sh — list Cost Anomaly Detection monitors, anomalies, subscriptions.
# Usage: anomalies.sh [--profile <p>] [--days <n>] [--min-impact <usd>]
#                     [--output-dir <path>] [--human]

set -euo pipefail

PROFILE=""
DAYS=90
MIN_IMPACT=100
OUT_DIR="reports"
HUMAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    PROFILE="$2"; shift 2 ;;
    --days)       DAYS="$2"; shift 2 ;;
    --min-impact) MIN_IMPACT="$2"; shift 2 ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --human)      HUMAN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-anomalies.json"

ce() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --region us-east-1 --output json ce "$@"
  else
    aws --region us-east-1 --output json ce "$@"
  fi
}

today=$(date -u +%Y-%m-%d)
if date -u -v-${DAYS}d +%Y-%m-%d >/dev/null 2>&1; then
  start=$(date -u -v-${DAYS}d +%Y-%m-%d)
else
  start=$(date -u -d "${DAYS} days ago" +%Y-%m-%d)
fi

echo "[1/3] Monitors..." >&2
monitors=$(ce get-anomaly-monitors 2>/dev/null || echo '{}')

echo "[2/3] Anomalies..." >&2
anomalies=$(ce get-anomalies \
  --date-interval "StartDate=$start,EndDate=$today" \
  --total-impact "NumericOperator=GREATER_THAN_OR_EQUAL,StartValue=$MIN_IMPACT" \
  2>/dev/null || echo '{}')

echo "[3/3] Subscriptions..." >&2
subs=$(ce get-anomaly-subscriptions 2>/dev/null || echo '{}')

jq -n \
  --argjson mons "$monitors" \
  --argjson anom "$anomalies" \
  --argjson subs "$subs" \
  --arg start "$start" --arg end "$today" \
  --argjson min_impact "$MIN_IMPACT" \
  '{
    period: { start: $start, end: $end },
    filter: { min_impact_usd: $min_impact },
    monitors: ($mons.AnomalyMonitors // [] | map({
      monitor_arn: .MonitorArn,
      monitor_name: .MonitorName,
      type: .MonitorType,
      dimension: .MonitorDimension,
      last_evaluated: .LastEvaluatedDate
    })),
    anomalies: ($anom.Anomalies // [] | map({
      anomaly_id: .AnomalyId,
      monitor_arn: .MonitorArn,
      start_date: .AnomalyStartDate,
      end_date: .AnomalyEndDate,
      root_cause_service: ((.RootCauses // [])[0].Service // null),
      root_cause_usage_type: ((.RootCauses // [])[0].UsageType // null),
      root_cause_region: ((.RootCauses // [])[0].Region // null),
      total_impact_usd: (.Impact.TotalImpact // 0),
      impact_pct: (.Impact.TotalImpactPercentage // 0),
      feedback: .Feedback
    }) | sort_by(-.total_impact_usd)),
    subscriptions: ($subs.AnomalySubscriptions // [] | map({
      subscription_arn: .SubscriptionArn,
      subscription_name: .SubscriptionName,
      threshold: (.Threshold // .ThresholdExpression // null),
      frequency: .Frequency,
      subscribers: (.Subscribers // [] | map({address: .Address, type: .Type}))
    })),
    gaps: {
      no_monitors: ((($mons.AnomalyMonitors // []) | length) == 0),
      no_subscriptions: ((($subs.AnomalySubscriptions // []) | length) == 0)
    },
    meta: { ce_api_calls: 3, estimated_cost_usd: 0.03 }
  }' > "$OUT_JSON"

echo "Wrote $OUT_JSON" >&2

if [[ "$HUMAN" == "1" ]]; then
  jq -r '
    def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
    "# AWS Cost Anomalies — last \(.period.start) → \(.period.end)",
    "",
    (if .gaps.no_monitors then
      "⚠ No anomaly monitors configured. Recommend enabling the default AWS-services monitor."
     else
      "Monitors: \(.monitors | length)"
     end),
    "",
    (if (.anomalies | length) > 0 then
      "## Anomalies (min impact: \(.filter.min_impact_usd | fmt))",
      "",
      "| Date | Service | Usage Type | Region | Impact | Δ% |",
      "|---|---|---|---|---:|---:|",
      (.anomalies[0:20][] |
        "| \(.start_date) | \(.root_cause_service // "-") | \(.root_cause_usage_type // "-") | \(.root_cause_region // "-") | \(.total_impact_usd | fmt) | \(.impact_pct)% |")
     else "No anomalies detected in this window." end)
  ' "$OUT_JSON"
else
  cat "$OUT_JSON"
fi
