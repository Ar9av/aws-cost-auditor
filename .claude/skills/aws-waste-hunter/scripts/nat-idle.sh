#!/usr/bin/env bash
#
# nat-idle.sh — NAT Gateways with <1MB BytesOutToSource over last 14 days.
# Usage: nat-idle.sh --profile <p> [--region <r>] [--regions <r1,r2>]
#
# NAT Gateways cost ~$32.85/month just for existing (hourly charge), before
# any bytes processed. Idle NATs are pure waste.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

end=$(days_ago 0)
start=$(days_ago 14)
THRESHOLD_BYTES=1000000   # 1 MB total over 14 days

scan_region() {
  local region="$1"
  local factor
  factor=$(region_factor "$region")

  local nats
  nats=$(aws_ ec2 describe-nat-gateways --region "$region" \
    --filter Name=state,Values=available \
    --query 'NatGateways[].{id:NatGatewayId,vpc:VpcId,subnet:SubnetId,created:CreateTime,tags:Tags}' \
    2>/dev/null || echo '[]')

  [[ "$(jq 'length' <<<"$nats")" == "0" ]] && return 0

  while read -r entry; do
    [[ -z "$entry" ]] && continue
    local id vpc subnet created
    id=$(jq -r '.id' <<<"$entry")
    vpc=$(jq -r '.vpc' <<<"$entry")
    subnet=$(jq -r '.subnet' <<<"$entry")
    created=$(jq -r '.created' <<<"$entry")

    # Get total BytesOutToSource from CloudWatch
    local metric
    metric=$(aws_ cloudwatch get-metric-statistics --region "$region" \
      --namespace AWS/NATGateway \
      --metric-name BytesOutToSource \
      --statistics Sum \
      --period 1209600 \
      --start-time "$start" \
      --end-time "$end" \
      --dimensions "Name=NatGatewayId,Value=$id" 2>/dev/null || echo '{"Datapoints":[]}')

    local bytes
    bytes=$(jq '[.Datapoints[].Sum // 0] | add // 0' <<<"$metric")

    if (( $(echo "$bytes < $THRESHOLD_BYTES" | bc -l) )); then
      finding "nat-idle" "$region" "$id" "ec2:nat-gateway" \
        "$(jq -n --arg vpc "$vpc" --arg subnet "$subnet" --arg created "$created" --argjson bytes "$bytes" \
          '{vpc: $vpc, subnet: $subnet, created: $created, bytes_out_to_source_14d: $bytes}')" \
        "$(jq -n --argjson p "${PRICE[nat_gateway_hourly_month]}" --arg f "$factor" '($p * ($f | tonumber) * 100 | round) / 100')" \
        "NAT Gateway processed <1MB outbound in 14 days. If the VPC still has private workloads that need egress, investigate; otherwise delete."
    fi
  done < <(jq -c '.[]' <<<"$nats")
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
