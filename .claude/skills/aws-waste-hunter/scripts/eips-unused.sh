#!/usr/bin/env bash
#
# eips-unused.sh — Elastic IPs with no AssociationId are billed hourly.
# Usage: eips-unused.sh --profile <p> [--region <r>] [--regions <r1,r2>]

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

scan_region() {
  local region="$1"
  local factor
  factor=$(region_factor "$region")

  local raw
  raw=$(aws_ ec2 describe-addresses --region "$region" \
    --query 'Addresses[?AssociationId==`null`].{ip:PublicIp,allocId:AllocationId,domain:Domain,tags:Tags}' \
    2>/dev/null || echo '[]')

  [[ "$(jq 'length' <<<"$raw")" == "0" ]] && return 0

  jq -c --arg region "$region" --arg factor "$factor" \
       --argjson p "${PRICE[eip_idle_month]}" \
       '.[] | {
          check: "eip-unused",
          region: $region,
          resource_id: (.allocId // .ip),
          resource_type: "ec2:eip",
          evidence: { public_ip: .ip, allocation_id: .allocId, domain: .domain },
          est_monthly_cost_usd: ($p * ($factor | tonumber) | . * 100 | round | . / 100),
          recommendation: "EIP not associated to any resource. Release with `aws ec2 release-address` if not needed."
        }' <<<"$raw"
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
