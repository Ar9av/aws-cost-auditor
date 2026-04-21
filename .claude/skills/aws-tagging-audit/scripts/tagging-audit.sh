#!/usr/bin/env bash
#
# tagging-audit.sh — measure cost-allocation-tag coverage and list untagged
# resources.
# Usage: tagging-audit.sh [--profile <p>] [--required <k1,k2,...>]
#                         [--days <n>] [--max-untagged <n>]
#                         [--output-dir <path>] [--human]

set -euo pipefail

PROFILE=""
REQUIRED="Project,Environment,Owner"
DAYS=30
MAX_UNTAGGED=100
OUT_DIR="reports"
HUMAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)       PROFILE="$2"; shift 2 ;;
    --required)      REQUIRED="$2"; shift 2 ;;
    --days)          DAYS="$2"; shift 2 ;;
    --max-untagged)  MAX_UNTAGGED="$2"; shift 2 ;;
    --output-dir)    OUT_DIR="$2"; shift 2 ;;
    --human)         HUMAN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-tagging-audit.json"

aws_global() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --region us-east-1 --output json "$@"
  else
    aws --region us-east-1 --output json "$@"
  fi
}

aws_tag() {
  # Resource tagging API is regional; loop across regions in a helper.
  local region="$1"; shift
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --region "$region" --output json "$@"
  else
    aws --region "$region" --output json "$@"
  fi
}

today=$(date -u +%Y-%m-%d)
if date -u -v-${DAYS}d +%Y-%m-%d >/dev/null 2>&1; then
  start=$(date -u -v-${DAYS}d +%Y-%m-%d)
else
  start=$(date -u -d "${DAYS} days ago" +%Y-%m-%d)
fi

IFS=',' read -ra REQS <<<"$REQUIRED"

# --- 1. Cost allocation tags (activation status) ---
echo "[1/3] Listing cost allocation tags..." >&2
cat_raw=$(aws_global ce list-cost-allocation-tags --max-results 200 2>/dev/null || echo '{}')
cat_list=$(jq '[.CostAllocationTags[]? | {key: .TagKey, status: .Status, type: .Type}]' <<<"$cat_raw")

# --- 2. Coverage per required key ---
echo "[2/3] Per-key coverage (will call CE once per required key)..." >&2
calls=1
coverage='[]'
for key in "${REQS[@]}"; do
  key=$(echo "$key" | xargs)   # trim
  raw=$(aws_global ce get-cost-and-usage \
    --time-period "Start=$start,End=$today" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by "Type=TAG,Key=$key" 2>/dev/null || echo '{}')
  calls=$((calls + 1))
  entry=$(jq --arg key "$key" '
    [.ResultsByTime[]?.Groups[]? | {
      tag_value: (.Keys[0] | sub("^[^$]*\\$"; "") | sub("^" + $key + "\\$"; "")),
      amount: (.Metrics.UnblendedCost.Amount | tonumber)
    }]
    | . as $g
    | {
        key: $key,
        total: ([$g[].amount] | add // 0),
        untagged_amount: ([$g[] | select(.tag_value == "" or .tag_value == null) | .amount] | add // 0),
        tagged_amount:   ([$g[] | select(.tag_value != "" and .tag_value != null) | .amount] | add // 0)
      }
    | . + { covered_pct: (if .total > 0 then (.tagged_amount / .total * 100 | . * 10 | round / 10) else 0 end) }
  ' <<<"$raw")
  coverage=$(jq --argjson c "$coverage" --argjson e "$entry" '$c + [$e]' <<<"null")
done

# --- 3. Untagged resources (tag API, per region) ---
echo "[3/3] Enumerating resources missing required keys..." >&2
regions=$(aws_global ec2 describe-regions --query 'Regions[].RegionName' --output json | jq -r '.[]')

# Build a filter that returns resources with ANY tag + resources with NO tag.
# The most reliable path: list ALL taggable resources, classify in jq.
untagged_list='[]'
scanned_regions=0
for r in $regions; do
  scanned_regions=$((scanned_regions + 1))
  # Paginated enumeration
  next=""
  while : ; do
    if [[ -n "$next" ]]; then
      raw=$(aws_tag "$r" resourcegroupstaggingapi get-resources \
        --pagination-token "$next" \
        --resources-per-page 100 2>/dev/null || echo '{}')
    else
      raw=$(aws_tag "$r" resourcegroupstaggingapi get-resources \
        --resources-per-page 100 2>/dev/null || echo '{}')
    fi

    entries=$(jq --argjson reqs "$(printf '%s\n' "${REQS[@]}" | jq -R . | jq -s .)" --arg region "$r" '
      .ResourceTagMappingList // [] | map(
        . as $res
        | {
            resource_arn: .ResourceARN,
            region: $region,
            service: ((.ResourceARN // "") | split(":")[2] // ""),
            existing_tags: (reduce (.Tags[]? | {(.Key): .Value}) as $t ({}; . + $t)),
          }
        | . + {
            missing_keys: [$reqs[] | select(.) as $k | select(($res.Tags // [] | map(.Key) | index($k)) == null) | $k]
          }
        | select(.missing_keys | length > 0)
      )
    ' <<<"$raw")
    untagged_list=$(jq --argjson u "$untagged_list" --argjson e "$entries" '$u + $e' <<<"null")
    next=$(jq -r '.PaginationToken // empty' <<<"$raw")
    [[ -z "$next" ]] && break
  done
done

total_untagged=$(jq 'length' <<<"$untagged_list")
untagged_sample=$(jq --argjson max "$MAX_UNTAGGED" '.[0:$max]' <<<"$untagged_list")

# Which required keys aren't active for cost allocation?
inactive_required=$(jq --argjson reqs "$(printf '%s\n' "${REQS[@]}" | jq -R . | jq -s .)" '
  [$reqs[] as $k | select(
    ([. []? | select(.key == $k and .status == "Active")] | length) == 0
  ) | $k]
' <<<"$cat_list")

# Sum of untagged-tag-value cost across required keys (approximate)
est_untagged_spend=$(jq '[.[].untagged_amount] | add // 0' <<<"$coverage")

jq -n \
  --arg start "$start" --arg end "$today" \
  --argjson reqs "$(printf '%s\n' "${REQS[@]}" | jq -R . | jq -s .)" \
  --argjson cat "$cat_list" \
  --argjson cov "$coverage" \
  --argjson inactive "$inactive_required" \
  --argjson total_untagged "$total_untagged" \
  --argjson sample "$untagged_sample" \
  --argjson est "$est_untagged_spend" \
  --argjson calls "$calls" \
  '{
    period: { start: $start, end: $end },
    required_keys: $reqs,
    cost_allocation_tags: $cat,
    coverage_by_key: $cov,
    untagged_resources: $sample,
    gaps: {
      inactive_required_keys: $inactive,
      total_untagged_resources: $total_untagged,
      estimated_untagged_monthly_cost_usd: $est
    },
    meta: { ce_api_calls: $calls, estimated_cost_usd: ($calls * 0.01) }
  }' | tee "$OUT_JSON" >/dev/null

echo "Wrote $OUT_JSON  (CE calls: $calls)" >&2

if [[ "$HUMAN" == "1" ]]; then
  jq -r '
    def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
    "# Tagging Audit — \(.period.start) → \(.period.end)",
    "",
    "Required keys: \(.required_keys | join(", "))",
    "",
    (if (.gaps.inactive_required_keys | length) > 0 then
      "⚠ Required keys NOT active for cost allocation: \(.gaps.inactive_required_keys | join(", "))"
     else empty end),
    "",
    "## Coverage per required key (last \(.period.start) → \(.period.end))",
    "| Key | Covered % | Tagged $ | Untagged $ |",
    "|---|---:|---:|---:|",
    (.coverage_by_key[] | "| \(.key) | \(.covered_pct)% | \(.tagged_amount | fmt) | \(.untagged_amount | fmt) |"),
    "",
    "## Untagged resource sample (showing \(.untagged_resources | length) of \(.gaps.total_untagged_resources))",
    "| Service | Region | Missing | Resource |",
    "|---|---|---|---|",
    (.untagged_resources[0:20][] | "| \(.service) | \(.region) | \(.missing_keys | join(", ")) | `\(.resource_arn)` |")
  ' "$OUT_JSON"
fi
