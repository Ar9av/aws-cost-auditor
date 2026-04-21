#!/usr/bin/env bash
#
# _lib.sh — shared helpers for waste-hunter scripts. Source, don't execute.

set -euo pipefail

: "${PROFILE:=}"
: "${OUT_DIR:=reports}"
: "${AWS_PAGER:=}"

mkdir -p "$OUT_DIR"

# --- Pricing table (us-east-1 list prices, April 2026) ---
# Multiply by region_factor for non-us-east-1.
declare -A PRICE=(
  [ebs_gp3_gb_month]=0.08
  [ebs_gp2_gb_month]=0.10
  [ebs_io2_gb_month]=0.125
  [ebs_st1_gb_month]=0.045
  [ebs_sc1_gb_month]=0.015
  [ebs_standard_gb_month]=0.05
  [snapshot_gb_month]=0.05
  [eip_idle_month]=3.60
  [nat_gateway_hourly_month]=32.85
  [elb_classic_hourly_month]=16.43
  [elb_v2_hourly_month]=16.43
  [cw_logs_gb_month]=0.03
  [rds_small_hourly_month]=17.52
)

region_factor() {
  # Rough multiplier for non-us-east-1. EBS and EC2 vary ~0–20%.
  case "${1:-}" in
    us-east-1|us-east-2|us-west-2) echo "1.00" ;;
    us-west-1)                     echo "1.02" ;;
    eu-west-1|eu-west-2|eu-central-1) echo "1.05" ;;
    ap-southeast-1|ap-southeast-2|ap-northeast-1) echo "1.10" ;;
    ap-south-1)                    echo "1.10" ;;
    sa-east-1)                     echo "1.25" ;;
    *) echo "1.10" ;;
  esac
}

# aws wrapper respecting --profile
aws_() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --output json "$@"
  else
    aws --output json "$@"
  fi
}

# Enumerate enabled regions for this account.
list_regions() {
  aws_ ec2 describe-regions --region us-east-1 \
    --query 'Regions[].RegionName' --output json | jq -r '.[]' | sort
}

# Emit a single finding as JSON (compact).
finding() {
  jq -nc \
    --arg check "$1" \
    --arg region "$2" \
    --arg rid "$3" \
    --arg rtype "$4" \
    --argjson evidence "$5" \
    --argjson cost "$6" \
    --arg rec "$7" \
    '{
      check: $check,
      region: $region,
      resource_id: $rid,
      resource_type: $rtype,
      evidence: $evidence,
      est_monthly_cost_usd: $cost,
      recommendation: $rec
    }'
}

ts() { date -u +%Y-%m-%d; }

parse_args() {
  # POSIX-y arg parser sets PROFILE, REGION, OUT_DIR, REGIONS globals.
  PROFILE=""
  REGION=""
  REGIONS=""
  OUT_DIR="reports"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)    PROFILE="$2"; shift 2 ;;
      --region)     REGION="$2"; shift 2 ;;
      --regions)    REGIONS="$2"; shift 2 ;;
      --output-dir) OUT_DIR="$2"; shift 2 ;;
      *) echo "unknown arg: $1" >&2; return 2 ;;
    esac
  done
  export PROFILE REGION REGIONS OUT_DIR
}

# Compute a date "N days ago" compatibly.
days_ago() {
  local n="$1"
  if date -u -v-${n}d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -v-${n}d +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "${n} days ago" +%Y-%m-%dT%H:%M:%SZ
  fi
}
