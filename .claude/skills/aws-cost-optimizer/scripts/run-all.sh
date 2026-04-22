#!/usr/bin/env bash
#
# run-all.sh — run COH, Compute Optimizer, Trusted Advisor, SP/RI utilization.
# Usage: run-all.sh [--profile <p>] [--output-dir <path>] [--human]

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

here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)

common_args=(--profile "$PROFILE" --output-dir "$OUT_DIR")

echo "== Cost Optimization Hub ==" >&2
coh=$(bash "$here/cost-optimization-hub.sh" "${common_args[@]}" 2>/dev/null | jq '.' || echo '{}')

echo "== Compute Optimizer ==" >&2
co=$(bash "$here/compute-optimizer.sh" "${common_args[@]}" 2>/dev/null | jq '.' || echo '{}')

echo "== Trusted Advisor ==" >&2
ta=$(bash "$here/trusted-advisor.sh" "${common_args[@]}" 2>/dev/null | jq '.' || echo '{}')

echo "== SP/RI Utilization ==" >&2
spri=$(bash "$here/sp-ri-utilization.sh" "${common_args[@]}" 2>/dev/null | jq '.' || echo '{}')

# Build the cross-source ranked opportunity list
ranked=$(jq -n --argjson coh "$coh" --argjson co "$co" --argjson ta "$ta" '
  [
    ($coh.recommendations // [] | map({
      source: "cost-optimization-hub",
      action_type: .action_type,
      resource_type: .resource_type,
      resource_id: .resource_id,
      region: .region,
      current_monthly: .current_monthly_cost,
      estimated_monthly_savings: .estimated_monthly_savings,
      implementation_effort: .implementation_effort,
      restart_needed: .restart_needed,
      rationale: "COH recommendation"
    })),
    ($co.by_resource_type.ec2_instances.recommendations // [] | map({
      source: "compute-optimizer",
      action_type: "Rightsize",
      resource_type: "Ec2Instance",
      resource_id: .resource_id,
      current_monthly: null,
      estimated_monthly_savings: (.top_recommendation.savings_opportunity.monthly_amount // 0),
      implementation_effort: (.top_recommendation.migration_effort // null),
      rationale: ("Finding: " + .finding + ", current " + .current_type)
    })),
    ($co.by_resource_type.ebs_volumes.recommendations // [] | map({
      source: "compute-optimizer",
      action_type: "Rightsize",
      resource_type: "EbsVolume",
      resource_id: .volume_arn,
      estimated_monthly_savings: .estimated_monthly_savings,
      rationale: ("Finding: " + .finding)
    })),
    ($co.by_resource_type.lambda.recommendations // [] | map({
      source: "compute-optimizer",
      action_type: "Rightsize",
      resource_type: "LambdaFunction",
      resource_id: .function_arn,
      estimated_monthly_savings: .estimated_monthly_savings,
      rationale: ("Finding: " + .finding + ", current memory " + (.current_memory_mb | tostring) + "MB")
    })),
    ($co.by_resource_type.rds.recommendations // [] | map({
      source: "compute-optimizer",
      action_type: "Rightsize",
      resource_type: "RdsDbInstance",
      resource_id: .db_arn,
      estimated_monthly_savings: .estimated_monthly_savings,
      rationale: ("Finding: " + .finding + ", current " + .current)
    })),
    ($ta.checks // [] | map({
      source: "trusted-advisor",
      action_type: .check_name,
      resource_type: "various",
      resource_id: (.flagged_resources[0].resource_id // "multiple"),
      estimated_monthly_savings: .estimated_monthly_savings,
      rationale: ("TA check: " + .check_name + ", " + (.resources_flagged | tostring) + " resources flagged")
    }))
  ] | flatten | sort_by(-(.estimated_monthly_savings // 0))
')

total=$(jq '[.[] | .estimated_monthly_savings // 0] | add // 0' <<<"$ranked")

OUT_JSON="$OUT_DIR/$TS-optimizer-summary.json"

jq -n \
  --argjson coh "$coh" \
  --argjson co "$co" \
  --argjson ta "$ta" \
  --argjson spri "$spri" \
  --argjson ranked "$ranked" \
  --argjson total "$total" \
  '{
    generated_at: (now | todate),
    sources: {
      cost_optimization_hub: $coh,
      compute_optimizer: $co,
      trusted_advisor: $ta,
      sp_ri_utilization: $spri
    },
    ranked_opportunities: $ranked,
    total_estimated_monthly_savings_usd: $total
  }' > "$OUT_JSON"

echo "Wrote $OUT_JSON  (total ranked savings: \$$total/mo)" >&2

if [[ "$HUMAN" == "1" ]]; then
  jq -r '
    def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
    "# AWS Cost Optimizer Summary — \(.generated_at)",
    "",
    "Total estimated monthly savings: \(.total_estimated_monthly_savings_usd | fmt)",
    "",
    "## Top 20 opportunities across all sources",
    "",
    "| Source | Action | Resource | Region | Savings/mo | Effort |",
    "|---|---|---|---|---:|---|",
    (.ranked_opportunities[0:20][] |
      "| \(.source) | \(.action_type) | `\(.resource_id // "-")` | \(.region // "-") | \((.estimated_monthly_savings // 0) | fmt) | \(.implementation_effort // "-") |")
  ' "$OUT_JSON"
else
  cat "$OUT_JSON"
fi
