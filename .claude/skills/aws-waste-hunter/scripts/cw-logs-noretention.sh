#!/usr/bin/env bash
#
# cw-logs-noretention.sh — CloudWatch Log Groups with no retention policy.
# These grow forever; $0.03/GB-month adds up fast.
# Usage: cw-logs-noretention.sh --profile <p> [--region <r>] [--regions <r1,r2>]

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

scan_region() {
  local region="$1"
  local factor
  factor=$(region_factor "$region")

  local lgs
  lgs=$(aws_ logs describe-log-groups --region "$region" \
    --query 'logGroups[].{name:logGroupName,retention:retentionInDays,stored:storedBytes,created:creationTime}' \
    2>/dev/null || echo '[]')

  jq -c --arg region "$region" --arg factor "$factor" \
       --argjson p "${PRICE[cw_logs_gb_month]}" \
       '
      .[] | select(.retention == null)
          | {
              check: "cw-logs-noretention",
              region: $region,
              resource_id: .name,
              resource_type: "logs:log-group",
              evidence: {
                stored_bytes: .stored,
                stored_gb: ((.stored // 0) / (1024*1024*1024) | . * 100 | round / 100),
                retention_days: null,
                created_ms: .created
              },
              est_monthly_cost_usd: (((.stored // 0) / (1024*1024*1024)) * $p * ($factor | tonumber) * 100 | round) / 100,
              recommendation: "Set a retention policy. 30-90d is typical for app logs, 365d for audit/compliance. Without one, storage grows forever."
            }
      ' <<<"$lgs"
}

if [[ -n "${REGION:-}" ]]; then
  regions="$REGION"
elif [[ -n "${REGIONS:-}" ]]; then
  regions=$(tr ',' ' ' <<<"$REGIONS")
else
  regions=$(list_regions | tr '\n' ' ')
fi

for r in $regions; do
  scan_region "$r"
done | jq -s '.'
