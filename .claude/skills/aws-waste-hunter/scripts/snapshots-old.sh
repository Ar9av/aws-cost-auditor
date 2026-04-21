#!/usr/bin/env bash
#
# snapshots-old.sh — EBS snapshots >180 days old whose source volume no
# longer exists (orphans).
# Usage: snapshots-old.sh --profile <p> [--region <r>] [--regions <r1,r2>]

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

AGE_CUTOFF=$(days_ago 180)

scan_region() {
  local region="$1"
  local factor
  factor=$(region_factor "$region")
  local acct
  acct=$(aws_ sts get-caller-identity --region "$region" --query Account --output text 2>/dev/null || echo "")
  [[ -z "$acct" ]] && return 0

  # Snapshots we own
  local snaps
  snaps=$(aws_ ec2 describe-snapshots --region "$region" \
    --owner-ids "$acct" \
    --query 'Snapshots[].{id:SnapshotId,volume:VolumeId,size:VolumeSize,started:StartTime,desc:Description}' \
    2>/dev/null || echo '[]')

  # Existing volume IDs in the region
  local vols
  vols=$(aws_ ec2 describe-volumes --region "$region" \
    --query 'Volumes[].VolumeId' 2>/dev/null || echo '[]')

  jq -c --arg region "$region" --arg cutoff "$AGE_CUTOFF" --arg factor "$factor" \
       --argjson vols "$vols" \
       --argjson p "${PRICE[snapshot_gb_month]}" \
       '
      .[] | select(.started < $cutoff)
          | . as $s
          | select(([$vols[]] | index($s.volume)) == null)
          | {
              check: "snapshot-old-orphan",
              region: $region,
              resource_id: $s.id,
              resource_type: "ec2:snapshot",
              evidence: {
                source_volume: $s.volume,
                size_gb: $s.size,
                started: $s.started,
                description: $s.desc,
                source_volume_exists: false
              },
              est_monthly_cost_usd: ($s.size * $p * ($factor | tonumber) * 100 | round) / 100,
              recommendation: "Snapshot older than 180 days and source volume no longer exists. Verify no AMI depends on it, then delete."
            }
      ' <<<"$snaps"
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
