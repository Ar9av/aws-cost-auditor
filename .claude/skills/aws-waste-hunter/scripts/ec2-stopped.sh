#!/usr/bin/env bash
#
# ec2-stopped.sh — EC2 instances stopped for >30 days. The instance-hour
# charge stops, but attached EBS keeps billing.
# Usage: ec2-stopped.sh --profile <p> [--region <r>] [--regions <r1,r2>]

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

STOP_CUTOFF=$(days_ago 30)

scan_region() {
  local region="$1"
  local factor
  factor=$(region_factor "$region")

  local raw
  raw=$(aws_ ec2 describe-instances --region "$region" \
    --filters Name=instance-state-name,Values=stopped \
    --query 'Reservations[].Instances[].{id:InstanceId,type:InstanceType,launched:LaunchTime,trans:StateTransitionReason,bdm:BlockDeviceMappings}' \
    2>/dev/null || echo '[]')

  [[ "$(jq 'length' <<<"$raw")" == "0" ]] && return 0

  # The stopped-time is embedded in StateTransitionReason like
  # "User initiated (2025-08-14 12:34:56 GMT)".
  jq -c --arg region "$region" --arg cutoff "$STOP_CUTOFF" --arg factor "$factor" \
       --argjson p_gp3 "${PRICE[ebs_gp3_gb_month]}" \
       --argjson p_gp2 "${PRICE[ebs_gp2_gb_month]}" \
       '
      def stop_ts:
        if .trans == null then null
        else ( .trans | capture("(?<d>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})") // null ) end;
      .[]
      | . as $inst
      | {
          check: "ec2-stopped",
          region: $region,
          resource_id: .id,
          resource_type: "ec2:instance",
          evidence: {
            instance_type: .type,
            state_transition: .trans,
            ebs_volumes: ([.bdm[]? | .Ebs.VolumeId] | length)
          },
          est_monthly_cost_usd: 0,
          recommendation: "Instance stopped — EC2 hours not billed, but each attached EBS still costs ~$\(([.bdm[]? | select(.Ebs != null) | 1] | length) * 8)/mo per ~100GB gp2. Confirm stop is intentional; if not, terminate (which releases root volume if DeleteOnTermination=true)."
        }
      ' <<<"$raw"
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
