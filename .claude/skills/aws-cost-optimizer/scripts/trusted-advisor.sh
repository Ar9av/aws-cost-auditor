#!/usr/bin/env bash
#
# trusted-advisor.sh — Trusted Advisor cost checks. Requires Business Support+.
# Usage: trusted-advisor.sh [--profile <p>] [--output-dir <path>]

set -euo pipefail

PROFILE=""
OUT_DIR="reports"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    PROFILE="$2"; shift 2 ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-trusted-advisor.json"

aws_() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --region us-east-1 --output json "$@"
  else
    aws --region us-east-1 --output json "$@"
  fi
}

# List all cost-optimization checks
checks_raw=$(aws_ support describe-trusted-advisor-checks --language en 2>&1 || echo "__err__")
if grep -qiE 'SubscriptionRequired|AccessDenied|not authorized' <<<"$checks_raw"; then
  jq -n '{available: false, note: "Trusted Advisor API requires Business Support+ or Enterprise Support. Basic/Developer plans can only view the 7 core checks in the console."}' | tee "$OUT_JSON"
  exit 0
fi

cost_checks=$(jq '.checks | map(select(.category == "cost_optimizing"))' <<<"$checks_raw")

results="[]"
while read -r id; do
  [[ -z "$id" ]] && continue
  name=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .name' <<<"$cost_checks")
  echo "[+] $name ($id)" >&2
  res=$(aws_ support describe-trusted-advisor-check-result --check-id "$id" --language en 2>/dev/null || echo '{}')
  entry=$(jq -n --arg id "$id" --arg name "$name" --argjson res "$res" \
    '{
      check_id: $id,
      check_name: $name,
      status: ($res.result.status // "unknown"),
      resources_flagged: ($res.result.resourcesSummary.resourcesFlagged // 0),
      estimated_monthly_savings: ($res.result.categorySpecificSummary.costOptimizing.estimatedMonthlySavings // 0),
      estimated_savings_pct: ($res.result.categorySpecificSummary.costOptimizing.estimatedPercentMonthlySavings // 0),
      flagged_resources: (($res.result.flaggedResources // []) | map({
        resource_id: .resourceId,
        region: .region,
        status: .status,
        metadata: .metadata
      }))
    }')
  results=$(jq --argjson r "$results" --argjson e "$entry" '$r + [$e]' <<<"null")
done < <(jq -r '.[].id' <<<"$cost_checks")

total=$(jq '[.[].estimated_monthly_savings] | add // 0' <<<"$results")

jq -n \
  --argjson checks "$results" \
  --argjson total "$total" \
  '{
    available: true,
    total_estimated_monthly_savings_usd: $total,
    checks: ($checks | sort_by(-.estimated_monthly_savings))
  }' > "$OUT_JSON"

echo "Wrote $OUT_JSON  (est. savings: \$$total)" >&2
cat "$OUT_JSON"
