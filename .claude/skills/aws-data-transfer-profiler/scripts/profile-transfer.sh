#!/usr/bin/env bash
#
# profile-transfer.sh — decompose data-transfer spend by usage-type and bucket.
# Usage: profile-transfer.sh [--profile <p>] [--days <n>] [--nat-deep]
#                             [--output-dir <path>] [--human]

set -euo pipefail

PROFILE=""
DAYS=30
NAT_DEEP=0
OUT_DIR="reports"
HUMAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    PROFILE="$2"; shift 2 ;;
    --days)       DAYS="$2"; shift 2 ;;
    --nat-deep)   NAT_DEEP=1; shift ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --human)      HUMAN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-data-transfer.json"

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

# Filter: match any usage type that smells like data transfer.
# We pull broad and classify in jq.
PATTERNS='["Bytes","NatGateway","DataTransfer","Regional","VpcEndpoint","PublicIPv4","CloudFront"]'

echo "[1] Pulling usage-type level transfer data..." >&2
raw=$(ce get-cost-and-usage \
  --time-period "Start=$start,End=$today" \
  --granularity MONTHLY \
  --metrics UnblendedCost UsageQuantity \
  --group-by Type=DIMENSION,Key=USAGE_TYPE \
  --group-by Type=DIMENSION,Key=REGION)

echo "[2] Grouping into buckets..." >&2

# Flatten into usage-type + region rows
flat=$(jq '
  [
    .ResultsByTime[] | .Groups[]? | {
      usage_type: .Keys[0],
      region: .Keys[1],
      amount: (.Metrics.UnblendedCost.Amount | tonumber),
      usage: (.Metrics.UsageQuantity.Amount | tonumber),
      unit: .Metrics.UsageQuantity.Unit
    }
  ]
  | map(select(.amount > 0))
' <<<"$raw")

# Classify each row into a bucket.
classified=$(jq '
  def bucket(ut):
    if (ut | test("NatGateway")) then "nat_processing"
    elif (ut | test("Regional-Bytes")) then "cross_az"
    elif (ut | test("[a-z]+-[a-z]+-AWS-(In|Out)-Bytes")) then "inter_region"
    elif (ut | test("CloudFront")) then "internet_egress"
    elif (ut | test("DataTransfer-Out-Bytes")) then "internet_egress"
    elif (ut | test("VpcEndpoint")) then "vpc_endpoints"
    elif (ut | test("PublicIPv4")) then "public_ipv4"
    elif (ut | test("Bytes")) then "other_transfer"
    else "other" end;

  map(. + { bucket: bucket(.usage_type) })
  | map(select(.bucket != "other"))
' <<<"$flat")

buckets=$(jq '
  group_by(.bucket)
  | map({
      bucket: .[0].bucket,
      amount: ([.[].amount] | add),
      usage_types: (group_by(.usage_type) | map({
        usage_type: .[0].usage_type,
        amount: ([.[].amount] | add),
        regions: (group_by(.region) | map({region: .[0].region, amount: ([.[].amount] | add)}) | sort_by(-.amount))
      }) | sort_by(-.amount) | .[0:10])
    })
  | sort_by(-.amount)
' <<<"$classified")

total=$(jq '[.[].amount] | add // 0' <<<"$buckets")

top_ut=$(jq '
  group_by(.usage_type)
  | map({
      usage_type: .[0].usage_type,
      amount: ([.[].amount] | add),
      bucket: .[0].bucket,
      top_region: (group_by(.region) | max_by([.[].amount] | add) | .[0].region)
    })
  | sort_by(-.amount) | .[0:15]
' <<<"$classified")

by_region=$(jq '
  group_by(.region)
  | map({region: .[0].region, amount: ([.[].amount] | add)})
  | sort_by(-.amount)
' <<<"$classified")

# Recommendations based on bucket shares
recs=$(jq --argjson t "$total" '
  map(select($t > 0 and .amount / $t > 0.10))
  | map(
      if .bucket == "nat_processing" then {
        action: "Create Gateway VPC Endpoints for S3 and DynamoDB in regions where NAT processing is high",
        estimated_monthly_saving_pct: "40-80% of NAT Bytes",
        rationale: "Gateway endpoints cost $0 and route private-subnet traffic to S3/DDB without NAT. NAT bytes charge $0.045/GB on top of the NAT hourly."
      }
      elif .bucket == "cross_az" then {
        action: "Audit cross-AZ traffic origins: LB cross-zone settings, EKS pod placement, Kafka/Elasticsearch replication",
        estimated_monthly_saving_pct: "20-50% of Regional-Bytes where feasible",
        rationale: "Cross-AZ traffic is $0.01/GB each way ($0.02/GB round-trip)."
      }
      elif .bucket == "internet_egress" then {
        action: "Put CloudFront in front of public origins (egress from origin → CF is free)",
        estimated_monthly_saving_pct: "30-60% of internet egress",
        rationale: "CloudFront has lower per-GB egress rates and the origin→CF hop is free."
      }
      elif .bucket == "inter_region" then {
        action: "Question whether cross-region replication / API calls are strictly needed",
        estimated_monthly_saving_pct: "Varies",
        rationale: "Inter-region transfer is $0.02/GB. Often accidental (DR replication left on, dev pointing at prod DB in another region)."
      }
      elif .bucket == "public_ipv4" then {
        action: "Move what you can to IPv6; release idle EIPs (run aws-waste-hunter)",
        estimated_monthly_saving_pct: "$3.60/month per IP freed",
        rationale: "Since Feb 2024 every public IPv4 address is chargeable."
      }
      else empty end)
' <<<"$buckets")

jq -n \
  --arg start "$start" --arg end "$today" --argjson days "$DAYS" \
  --argjson total "$total" \
  --argjson buckets "$buckets" \
  --argjson top_ut "$top_ut" \
  --argjson by_region "$by_region" \
  --argjson recs "$recs" \
  '{
    period: {start: $start, end: $end, days: $days},
    total_data_transfer_cost_usd: $total,
    buckets: $buckets,
    top_usage_types: $top_ut,
    by_region: $by_region,
    recommendations: $recs,
    meta: { ce_api_calls: 1, estimated_cost_usd: 0.01 }
  }' | tee "$OUT_JSON" >/dev/null

echo "Wrote $OUT_JSON  (total transfer cost: \$$total)" >&2

if [[ "$HUMAN" == "1" ]]; then
  jq -r '
    def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
    def pct(t): if t > 0 then (. / t * 100 | . * 10 | round / 10 | tostring + "%") else "0%" end;
    . as $root |
    "# Data Transfer Profile — \(.period.start) → \(.period.end)",
    "",
    "Total: \(.total_data_transfer_cost_usd | fmt)",
    "",
    "## By bucket",
    "| Bucket | Amount | % of transfer |",
    "|---|---:|---:|",
    (.buckets[] | "| \(.bucket) | \(.amount | fmt) | \(.amount | pct($root.total_data_transfer_cost_usd)) |"),
    "",
    "## Top usage types",
    "| Usage type | Bucket | Amount | Top region |",
    "|---|---|---:|---|",
    (.top_usage_types[] | "| \(.usage_type) | \(.bucket) | \(.amount | fmt) | \(.top_region // "-") |"),
    "",
    "## Recommendations",
    "",
    (.recommendations[]? |
      "- **\(.action)**",
      "  - Potential: \(.estimated_monthly_saving_pct)",
      "  - Why: \(.rationale)")
  ' "$OUT_JSON"
fi
