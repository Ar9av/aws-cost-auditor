#!/usr/bin/env bash
#
# ebs-unattached.sh — EBS volumes in `available` state (not attached).
# Usage: ebs-unattached.sh --profile <p> [--region <r>] [--regions <r1,r2>]

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

scan_region() {
  local region="$1"
  local factor
  factor=$(region_factor "$region")

  local vols
  vols=$(aws_ ec2 describe-volumes --region "$region" \
    --filters Name=status,Values=available \
    --query 'Volumes[].{id:VolumeId,size:Size,type:VolumeType,iops:Iops,throughput:Throughput,created:CreateTime,tags:Tags}' \
    2>/dev/null || echo '[]')

  local count
  count=$(jq 'length' <<<"$vols")
  [[ "$count" == "0" ]] && return 0

  jq -c --arg region "$region" --arg factor "$factor" \
       --argjson p_gp3 "${PRICE[ebs_gp3_gb_month]}" \
       --argjson p_gp2 "${PRICE[ebs_gp2_gb_month]}" \
       --argjson p_io2 "${PRICE[ebs_io2_gb_month]}" \
       --argjson p_st1 "${PRICE[ebs_st1_gb_month]}" \
       --argjson p_sc1 "${PRICE[ebs_sc1_gb_month]}" \
       '.[] | {
          check: "ebs-unattached",
          region: $region,
          resource_id: .id,
          resource_type: "ec2:volume",
          evidence: {
            state: "available",
            size_gb: .size,
            volume_type: .type,
            iops: .iops,
            throughput: .throughput,
            created: .created
          },
          est_monthly_cost_usd: (
            (.size * (
              if .type == "gp3" then $p_gp3
              elif .type == "gp2" then $p_gp2
              elif .type == "io2" or .type == "io1" then $p_io2
              elif .type == "st1" then $p_st1
              elif .type == "sc1" then $p_sc1
              else $p_gp2 end
            ) * ($factor | tonumber))
            | . * 100 | round | . / 100
          ),
          recommendation: ("Detached since creation. Snapshot-and-delete if not needed. Volume type: " + .type + ", size: " + (.size | tostring) + " GB.")
        }' <<<"$vols"
}

# Single region if --region given, else iterate all.
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
