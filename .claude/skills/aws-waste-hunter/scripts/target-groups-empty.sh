#!/usr/bin/env bash
#
# target-groups-empty.sh — ALB/NLB target groups with no registered targets.
# Usage: target-groups-empty.sh --profile <p> [--region <r>] [--regions <r1,r2>]

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

scan_region() {
  local region="$1"

  local tgs
  tgs=$(aws_ elbv2 describe-target-groups --region "$region" \
    --query 'TargetGroups[].{arn:TargetGroupArn,name:TargetGroupName,type:TargetType,lbs:LoadBalancerArns}' \
    2>/dev/null || echo '[]')

  while read -r t; do
    [[ -z "$t" ]] && continue
    local arn name lbs
    arn=$(jq -r '.arn' <<<"$t")
    name=$(jq -r '.name' <<<"$t")
    lbs=$(jq -c '.lbs' <<<"$t")

    local cnt
    cnt=$(aws_ elbv2 describe-target-health --region "$region" \
      --target-group-arn "$arn" --query 'length(TargetHealthDescriptions)' 2>/dev/null || echo 0)

    if [[ "$cnt" == "0" ]]; then
      finding "target-group-empty" "$region" "$name" "elasticloadbalancing:target-group" \
        "$(jq -nc --arg arn "$arn" --argjson lbs "$lbs" '{arn: $arn, load_balancers_attached: ($lbs | length), targets: 0}')" \
        0.00 \
        "Target group with 0 registered targets. If its LB is also idle, delete both."
    fi
  done < <(jq -c '.[]' <<<"$tgs")
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
