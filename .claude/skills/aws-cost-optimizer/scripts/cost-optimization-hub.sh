#!/usr/bin/env bash
#
# cost-optimization-hub.sh — pull the top Cost Optimization Hub
# recommendations with savings estimates.
#
# Usage: cost-optimization-hub.sh [--profile <p>] [--max <n>]
#                                 [--output-dir <path>] [--human]
#
# COH is a free service but must be enrolled per-account in the Billing
# console (one-time click).

set -euo pipefail

PROFILE=""
MAX=100
OUT_DIR="reports"
HUMAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    PROFILE="$2"; shift 2 ;;
    --max)        MAX="$2"; shift 2 ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --human)      HUMAN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-coh.json"

aws_() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --region us-east-1 --output json "$@"
  else
    aws --region us-east-1 --output json "$@"
  fi
}

# Check enrollment
enroll=$(aws_ cost-optimization-hub list-enrollment-statuses 2>&1 || echo "__denied__")
if grep -qiE 'AccessDenied|not authorized' <<<"$enroll"; then
  jq -n '{enrolled: false, reason: "access-denied", note: "Grant cost-optimization-hub:ListEnrollmentStatuses or enrol in Cost Optimization Hub (Billing console → Cost Optimization Hub → Preferences)."}' | tee "$OUT_JSON"
  exit 0
fi

is_active=$(jq -r '.items[0].status // "Inactive"' <<<"$enroll" 2>/dev/null || echo "Inactive")
if [[ "$is_active" != "Active" ]]; then
  jq -n --arg status "$is_active" \
    '{enrolled: false, status: $status, note: "Account not enrolled in Cost Optimization Hub. Enrol once in Billing console → Cost Optimization Hub → Preferences to get recommendations."}' \
    | tee "$OUT_JSON"
  exit 0
fi

# Summary first (shows total opportunity)
summary=$(aws_ cost-optimization-hub list-recommendation-summaries \
  --group-by ActionType 2>/dev/null || echo '{}')

# All recommendations, sorted by savings
recs=$(aws_ cost-optimization-hub list-recommendations \
  --order-by "Key=EstimatedMonthlySavings,Order=Desc" \
  --max-results "$MAX" 2>/dev/null || echo '{}')

jq -n \
  --argjson summary "$summary" \
  --argjson recs "$recs" \
  '{
    enrolled: true,
    summary: {
      total_estimated_monthly_savings: ($summary.estimatedTotalDedupedSavings // 0),
      currency: ($summary.currencyCode // "USD"),
      by_action_type: ($summary.items // [] | map({
        action_type: .group,
        count: .recommendationCount,
        estimated_monthly_savings: (.estimatedMonthlySavings // 0)
      }))
    },
    recommendations: ($recs.items // [] | map({
      recommendation_id: .recommendationId,
      action_type: .actionType,
      resource_id: .resourceId,
      resource_arn: .resourceArn,
      resource_type: .currentResourceType,
      recommended_resource_type: .recommendedResourceType,
      region: .region,
      account_id: .accountId,
      current_monthly_cost: (.estimatedMonthlyCost // 0),
      estimated_monthly_savings: (.estimatedMonthlySavings // 0),
      savings_pct: (.estimatedSavingsPercentage // 0),
      implementation_effort: .implementationEffort,
      restart_needed: .restartNeeded,
      rollback_possible: .rollbackPossible
    }))
  }' > "$OUT_JSON"

echo "Wrote $OUT_JSON" >&2

if [[ "$HUMAN" == "1" ]]; then
  jq -r '
    def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
    if .enrolled | not then
      "Cost Optimization Hub not enrolled. \(.note // "")"
    else
      "# Cost Optimization Hub",
      "",
      "Total estimated monthly savings: \(.summary.total_estimated_monthly_savings | fmt)",
      "",
      "## By action type",
      "| Action | Count | Est monthly |",
      "|---|---:|---:|",
      (.summary.by_action_type[] | "| \(.action_type) | \(.count) | \(.estimated_monthly_savings | fmt) |"),
      "",
      "## Top 20 recommendations",
      "| Action | Resource | Region | Current $/mo | Savings $/mo | Effort |",
      "|---|---|---|---:|---:|---|",
      (.recommendations[0:20][] |
        "| \(.action_type) | `\(.resource_id // "-")` (\(.resource_type // "-")) | \(.region) | \(.current_monthly_cost | fmt) | \(.estimated_monthly_savings | fmt) | \(.implementation_effort // "-") |")
    end
  ' "$OUT_JSON"
else
  cat "$OUT_JSON"
fi
