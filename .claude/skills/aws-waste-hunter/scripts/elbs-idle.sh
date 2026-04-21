#!/usr/bin/env bash
#
# elbs-idle.sh — ALB/NLB/CLB with 0 healthy targets.
# Usage: elbs-idle.sh --profile <p> [--region <r>] [--regions <r1,r2>]

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

scan_region() {
  local region="$1"
  local factor
  factor=$(region_factor "$region")

  # v2 (ALB/NLB)
  local lbs
  lbs=$(aws_ elbv2 describe-load-balancers --region "$region" \
    --query 'LoadBalancers[].{arn:LoadBalancerArn,name:LoadBalancerName,type:Type,created:CreatedTime,scheme:Scheme}' \
    2>/dev/null || echo '[]')

  while read -r lb; do
    [[ -z "$lb" ]] && continue
    local arn name type created
    arn=$(jq -r '.arn' <<<"$lb")
    name=$(jq -r '.name' <<<"$lb")
    type=$(jq -r '.type' <<<"$lb")
    created=$(jq -r '.created' <<<"$lb")

    # Target groups attached to this LB
    local tgs
    tgs=$(aws_ elbv2 describe-target-groups --region "$region" \
      --load-balancer-arn "$arn" \
      --query 'TargetGroups[].TargetGroupArn' 2>/dev/null || echo '[]')

    local healthy=0 total=0
    while read -r tg; do
      [[ -z "$tg" ]] && continue
      local health
      health=$(aws_ elbv2 describe-target-health --region "$region" \
        --target-group-arn "$tg" --query 'TargetHealthDescriptions[].TargetHealth.State' 2>/dev/null || echo '[]')
      local this_total this_healthy
      this_total=$(jq 'length' <<<"$health")
      this_healthy=$(jq '[.[] | select(. == "healthy")] | length' <<<"$health")
      total=$((total + this_total))
      healthy=$((healthy + this_healthy))
    done < <(jq -r '.[]' <<<"$tgs")

    if (( healthy == 0 )); then
      finding "elb-idle" "$region" "$name" "elasticloadbalancing:loadbalancer" \
        "$(jq -n --arg arn "$arn" --arg type "$type" --arg created "$created" \
               --argjson t "$total" --argjson h "$healthy" \
          '{arn: $arn, type: $type, created: $created, targets_total: $t, targets_healthy: $h}')" \
        "$(jq -n --argjson p "${PRICE[elb_v2_hourly_month]}" --arg f "$factor" '($p * ($f | tonumber) * 100 | round) / 100')" \
        "Load balancer has 0 healthy targets. Verify traffic policy; delete if truly unused."
    fi
  done < <(jq -c '.[]' <<<"$lbs")

  # Classic ELB
  local clbs
  clbs=$(aws_ elb describe-load-balancers --region "$region" \
    --query 'LoadBalancerDescriptions[].{name:LoadBalancerName,created:CreatedTime,instances:Instances}' \
    2>/dev/null || echo '[]')

  while read -r clb; do
    [[ -z "$clb" ]] && continue
    local name created instances
    name=$(jq -r '.name' <<<"$clb")
    created=$(jq -r '.created' <<<"$clb")
    instances=$(jq '[.instances // [] | .[].InstanceId]' <<<"$clb")
    if [[ "$(jq 'length' <<<"$instances")" == "0" ]]; then
      finding "elb-idle" "$region" "$name" "elasticloadbalancing:classic-loadbalancer" \
        "$(jq -n --arg created "$created" '{type: "classic", created: $created, instances: 0}')" \
        "$(jq -n --argjson p "${PRICE[elb_classic_hourly_month]}" --arg f "$factor" '($p * ($f | tonumber) * 100 | round) / 100')" \
        "Classic ELB with 0 registered instances. Delete if truly unused."
    fi
  done < <(jq -c '.[]' <<<"$clbs")
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
