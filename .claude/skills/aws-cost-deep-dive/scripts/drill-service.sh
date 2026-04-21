#!/usr/bin/env bash
#
# drill-service.sh — break down cost for one AWS service along multiple axes.
#
# Usage:
#   drill-service.sh --service "<service name>" [--profile <name>]
#                    [--days <n>] [--by-az] [--by-account] [--with-resources]
#                    [--output-dir <path>] [--human]
#
# --days: window in days (default 30). --with-resources forces the last 14d.
#
# Cost: ~$0.03 base, +$0.01 per optional axis, +$0.02-0.05 for --with-resources.

set -euo pipefail

PROFILE=""
SERVICE=""
DAYS=30
BY_AZ=0
BY_ACCOUNT=0
WITH_RESOURCES=0
OUT_DIR="reports"
HUMAN=0
METRIC="UnblendedCost"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)         PROFILE="$2"; shift 2 ;;
    --service)         SERVICE="$2"; shift 2 ;;
    --days)            DAYS="$2"; shift 2 ;;
    --by-az)           BY_AZ=1; shift ;;
    --by-account)      BY_ACCOUNT=1; shift ;;
    --with-resources)  WITH_RESOURCES=1; shift ;;
    --output-dir)      OUT_DIR="$2"; shift 2 ;;
    --human)           HUMAN=1; shift ;;
    -h|--help)         sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SERVICE" ]]; then
  echo "error: --service is required" >&2
  echo "hint: run aws-cost-snapshot first to see service names" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"
SLUG=$(echo "$SERVICE" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-')
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-deep-$SLUG.json"

# Dates
today=$(date -u +%Y-%m-%d)
if date -u -v-${DAYS}d +%Y-%m-%d >/dev/null 2>&1; then
  start=$(date -u -v-${DAYS}d +%Y-%m-%d)
else
  start=$(date -u -d "${DAYS} days ago" +%Y-%m-%d)
fi

# Resource-level is hourly, 14 days max.
if [[ "$WITH_RESOURCES" == "1" ]]; then
  if date -u -v-14d +%Y-%m-%d >/dev/null 2>&1; then
    res_start=$(date -u -v-14d +%Y-%m-%d)
  else
    res_start=$(date -u -d "14 days ago" +%Y-%m-%d)
  fi
fi

ce() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --region us-east-1 --output json ce "$@"
  else
    aws --region us-east-1 --output json ce "$@"
  fi
}

FILTER=$(jq -n --arg s "$SERVICE" '{
  Dimensions: { Key: "SERVICE", Values: [$s] }
}')

CALLS=0

echo "[1] Total for $SERVICE over last $DAYS days..." >&2
total_raw=$(ce get-cost-and-usage \
  --time-period "Start=$start,End=$today" \
  --granularity MONTHLY \
  --metrics "$METRIC" \
  --filter "$FILTER")
CALLS=$((CALLS + 1))
total=$(jq "[.ResultsByTime[].Total.$METRIC.Amount | tonumber] | add // 0" <<<"$total_raw")

echo "[2] By usage type..." >&2
ut_raw=$(ce get-cost-and-usage \
  --time-period "Start=$start,End=$today" \
  --granularity MONTHLY \
  --metrics "$METRIC" \
  --filter "$FILTER" \
  --group-by Type=DIMENSION,Key=USAGE_TYPE)
CALLS=$((CALLS + 1))
by_ut=$(jq "[.ResultsByTime[] | .Groups[]? | {
  usage_type: .Keys[0],
  amount: (.Metrics.$METRIC.Amount | tonumber)
}] | group_by(.usage_type) | map({
  usage_type: .[0].usage_type,
  amount: (map(.amount) | add)
}) | sort_by(-.amount) | .[0:20]" <<<"$ut_raw")

echo "[3] By region..." >&2
reg_raw=$(ce get-cost-and-usage \
  --time-period "Start=$start,End=$today" \
  --granularity MONTHLY \
  --metrics "$METRIC" \
  --filter "$FILTER" \
  --group-by Type=DIMENSION,Key=REGION)
CALLS=$((CALLS + 1))
by_region=$(jq "[.ResultsByTime[] | .Groups[]? | {
  region: .Keys[0],
  amount: (.Metrics.$METRIC.Amount | tonumber)
}] | group_by(.region) | map({
  region: .[0].region,
  amount: (map(.amount) | add)
}) | sort_by(-.amount)" <<<"$reg_raw")

echo "[4] By operation..." >&2
op_raw=$(ce get-cost-and-usage \
  --time-period "Start=$start,End=$today" \
  --granularity MONTHLY \
  --metrics "$METRIC" \
  --filter "$FILTER" \
  --group-by Type=DIMENSION,Key=OPERATION || echo '{"ResultsByTime":[]}')
CALLS=$((CALLS + 1))
by_op=$(jq "[.ResultsByTime[] | .Groups[]? | {
  operation: .Keys[0],
  amount: (.Metrics.$METRIC.Amount | tonumber)
}] | group_by(.operation) | map({
  operation: .[0].operation,
  amount: (map(.amount) | add)
}) | sort_by(-.amount) | .[0:10]" <<<"$op_raw")

by_az="null"
if [[ "$BY_AZ" == "1" ]]; then
  echo "[+] By AZ..." >&2
  az_raw=$(ce get-cost-and-usage \
    --time-period "Start=$start,End=$today" \
    --granularity MONTHLY \
    --metrics "$METRIC" \
    --filter "$FILTER" \
    --group-by Type=DIMENSION,Key=AZ || echo '{"ResultsByTime":[]}')
  CALLS=$((CALLS + 1))
  by_az=$(jq "[.ResultsByTime[] | .Groups[]? | {
    az: .Keys[0],
    amount: (.Metrics.$METRIC.Amount | tonumber)
  }] | group_by(.az) | map({
    az: .[0].az,
    amount: (map(.amount) | add)
  }) | sort_by(-.amount)" <<<"$az_raw")
fi

by_account="null"
if [[ "$BY_ACCOUNT" == "1" ]]; then
  echo "[+] By account..." >&2
  acct_raw=$(ce get-cost-and-usage \
    --time-period "Start=$start,End=$today" \
    --granularity MONTHLY \
    --metrics "$METRIC" \
    --filter "$FILTER" \
    --group-by Type=DIMENSION,Key=LINKED_ACCOUNT || echo '{"ResultsByTime":[]}')
  CALLS=$((CALLS + 1))
  by_account=$(jq "[.ResultsByTime[] | .Groups[]? | {
    account_id: .Keys[0],
    amount: (.Metrics.$METRIC.Amount | tonumber)
  }] | group_by(.account_id) | map({
    account_id: .[0].account_id,
    amount: (map(.amount) | add)
  }) | sort_by(-.amount)" <<<"$acct_raw")
fi

resource_json="null"
if [[ "$WITH_RESOURCES" == "1" ]]; then
  echo "[+] Resource-level (last 14d, hourly granularity — extra charge)..." >&2
  res_raw=$(ce get-cost-and-usage-with-resources \
    --time-period "Start=$res_start,End=$today" \
    --granularity HOURLY \
    --metrics "$METRIC" \
    --filter "$FILTER" \
    --group-by Type=DIMENSION,Key=RESOURCE_ID || echo '{"ResultsByTime":[]}')
  CALLS=$((CALLS + 1))
  resource_json=$(jq "{
    note: \"Hourly granularity, last 14 days. Requires resource-level data enabled in Cost Management preferences.\",
    top_resources: (
      [.ResultsByTime[] | .Groups[]? | {
        resource_id: .Keys[0],
        amount: (.Metrics.$METRIC.Amount | tonumber)
      }] | group_by(.resource_id) | map({
        resource_id: .[0].resource_id,
        amount: (map(.amount) | add)
      }) | sort_by(-.amount) | .[0:30]
    )
  }" <<<"$res_raw")
fi

COST=$(awk "BEGIN {printf \"%.2f\", $CALLS * 0.01 + ($WITH_RESOURCES == 1 ? 0.03 : 0)}")

# pct column on usage types
by_ut_with_pct=$(jq --argjson t "$total" '
  map(. + { pct: (if $t > 0 then (.amount / $t * 100 | . * 10 | round / 10) else 0 end) })
' <<<"$by_ut")

jq -n \
  --arg service "$SERVICE" \
  --arg start "$start" --arg end "$today" \
  --argjson total "$total" \
  --argjson byut "$by_ut_with_pct" \
  --argjson byreg "$by_region" \
  --argjson byop "$by_op" \
  --argjson byaz "$by_az" \
  --argjson byacct "$by_account" \
  --argjson byres "$resource_json" \
  --argjson calls "$CALLS" \
  --arg cost "$COST" \
  '{
    service: $service,
    period: { start: $start, end: $end, granularity: "MONTHLY" },
    total: $total,
    by_usage_type: $byut,
    by_region: $byreg,
    by_operation: $byop,
    by_az: $byaz,
    by_account: $byacct,
    resource_level: $byres,
    meta: {
      ce_api_calls: $calls,
      estimated_cost_usd: ($cost | tonumber),
      generated_at: (now | todate)
    }
  }' | tee "$OUT_JSON" >/dev/null

echo "Wrote $OUT_JSON  (CE calls: $CALLS, est. cost: \$$COST)" >&2

if [[ "$HUMAN" == "1" ]]; then
  jq -r '
    def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
    "# Deep dive: \(.service)",
    "Period: \(.period.start) → \(.period.end)  ·  Total: \(.total | fmt)",
    "",
    "## Top usage types",
    "| Usage type | Amount | % |",
    "|---|---:|---:|",
    (.by_usage_type[] | "| \(.usage_type) | \(.amount | fmt) | \(.pct)% |"),
    "",
    "## By region",
    "| Region | Amount |",
    "|---|---:|",
    (.by_region[] | "| \(.region) | \(.amount | fmt) |")
  ' "$OUT_JSON"
else
  cat "$OUT_JSON"
fi
