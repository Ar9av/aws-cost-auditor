#!/usr/bin/env bash
#
# rds-idle.sh — RDS instances with 0 DB connections over 14 days.
# Usage: rds-idle.sh --profile <p> [--region <r>] [--regions <r1,r2>]

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

end=$(days_ago 0)
start=$(days_ago 14)

scan_region() {
  local region="$1"
  local factor
  factor=$(region_factor "$region")

  local dbs
  dbs=$(aws_ rds describe-db-instances --region "$region" \
    --query 'DBInstances[].{id:DBInstanceIdentifier,class:DBInstanceClass,engine:Engine,status:DBInstanceStatus,multiaz:MultiAZ,storage:AllocatedStorage}' \
    2>/dev/null || echo '[]')

  [[ "$(jq 'length' <<<"$dbs")" == "0" ]] && return 0

  while read -r db; do
    [[ -z "$db" ]] && continue
    local id class engine status multiaz storage
    id=$(jq -r '.id' <<<"$db")
    class=$(jq -r '.class' <<<"$db")
    engine=$(jq -r '.engine' <<<"$db")
    status=$(jq -r '.status' <<<"$db")
    multiaz=$(jq -r '.multiaz' <<<"$db")
    storage=$(jq -r '.storage' <<<"$db")

    [[ "$status" != "available" ]] && continue

    local metric
    metric=$(aws_ cloudwatch get-metric-statistics --region "$region" \
      --namespace AWS/RDS --metric-name DatabaseConnections \
      --statistics Maximum \
      --period 1209600 \
      --start-time "$start" --end-time "$end" \
      --dimensions "Name=DBInstanceIdentifier,Value=$id" 2>/dev/null || echo '{"Datapoints":[]}')

    local max_conn
    max_conn=$(jq '[.Datapoints[].Maximum // 0] | max // 0' <<<"$metric")

    if (( $(echo "$max_conn == 0" | bc -l) )); then
      finding "rds-idle" "$region" "$id" "rds:db" \
        "$(jq -n --arg class "$class" --arg engine "$engine" --argjson multiaz "$multiaz" \
               --argjson storage "$storage" --argjson conn "$max_conn" \
          '{class: $class, engine: $engine, multiaz: $multiaz, storage_gb: $storage, max_connections_14d: $conn}')" \
        "$(jq -n --argjson base "${PRICE[rds_small_hourly_month]}" --arg f "$factor" '($base * 2 * ($f | tonumber) * 100 | round) / 100')" \
        "RDS instance has had 0 connections in the last 14 days. Snapshot-and-delete if truly unused. (Cost estimate is rough; actual depends on class size and storage.)"
    fi
  done < <(jq -c '.[]' <<<"$dbs")
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
