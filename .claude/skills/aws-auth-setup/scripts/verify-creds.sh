#!/usr/bin/env bash
#
# verify-creds.sh — confirm AWS credentials work and probe the audit permissions.
#
# Usage:
#   verify-creds.sh [--profile <name>] [--region <region>]
#
# On success, prints a single JSON object to stdout describing the caller
# identity and which permission blocks succeeded. Exits non-zero if
# sts:GetCallerIdentity itself fails.

set -euo pipefail

PROFILE=""
REGION="${AWS_REGION:-us-east-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

aws_cmd() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" --region "$REGION" --output json "$@"
  else
    aws --region "$REGION" --output json "$@"
  fi
}

# Probe helper: run a command, return "ok" on success, the error code
# ("AccessDenied", "OptInRequired", etc.) on failure.
probe() {
  local label="$1"; shift
  local out
  if out=$("$@" 2>&1 >/dev/null); then
    echo "ok"
  else
    # Pull the AWS error code out of the stderr text.
    if grep -qiE 'AccessDenied|is not authorized' <<<"$out"; then
      echo "denied"
    elif grep -qi 'OptInRequired|not enrolled|not subscribed' <<<"$out"; then
      echo "not-enrolled"
    elif grep -qi 'SubscriptionRequired|BusinessSupport' <<<"$out"; then
      echo "business-support-required"
    elif grep -qi 'ExpiredToken' <<<"$out"; then
      echo "expired-token"
    else
      echo "error"
    fi
  fi
}

# --- 1. Caller identity (must succeed) ---
if ! ident=$(aws_cmd sts get-caller-identity 2>&1); then
  echo "FATAL: sts:GetCallerIdentity failed" >&2
  echo "$ident" >&2
  echo "" >&2
  echo "Common causes:" >&2
  echo "  - No credentials: 'aws configure --profile <name>'" >&2
  echo "  - SSO token expired: 'aws sso login --profile <name>'" >&2
  echo "  - Wrong profile name: 'aws configure list-profiles'" >&2
  exit 1
fi

ACCOUNT_ID=$(jq -r '.Account' <<<"$ident")
USER_ARN=$(jq -r '.Arn' <<<"$ident")

# --- 2. Account alias (best-effort) ---
ALIAS=""
if alias_out=$(aws_cmd iam list-account-aliases 2>/dev/null); then
  ALIAS=$(jq -r '.AccountAliases[0] // ""' <<<"$alias_out")
fi

# --- 3. Permission probes (Cost Explorer is always us-east-1) ---
CE_STATUS=$(probe ce aws_cmd ce get-dimension-values \
  --time-period "Start=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d 'yesterday' +%Y-%m-%d),End=$(date -u +%Y-%m-%d)" \
  --dimension SERVICE --max-results 1)

COH_STATUS=$(probe coh aws_cmd cost-optimization-hub list-enrollment-statuses \
  --max-results 1)

CO_STATUS=$(probe co aws_cmd compute-optimizer get-enrollment-status)

TA_STATUS=$(probe ta aws_cmd support describe-trusted-advisor-checks --language en --max-items 1)

EC2_STATUS=$(probe ec2 aws_cmd ec2 describe-regions --max-results 1)

ORG_STATUS=$(probe org aws_cmd organizations describe-organization)

TAG_STATUS=$(probe tag aws_cmd resourcegroupstaggingapi get-tag-keys)

# --- 4. Emit result ---
jq -n \
  --arg account "$ACCOUNT_ID" \
  --arg alias "$ALIAS" \
  --arg arn "$USER_ARN" \
  --arg region "$REGION" \
  --arg profile "${PROFILE:-${AWS_PROFILE:-env}}" \
  --arg ce "$CE_STATUS" \
  --arg coh "$COH_STATUS" \
  --arg co "$CO_STATUS" \
  --arg ta "$TA_STATUS" \
  --arg ec2 "$EC2_STATUS" \
  --arg org "$ORG_STATUS" \
  --arg tag "$TAG_STATUS" \
  '{
    account_id: $account,
    account_alias: $alias,
    user_arn: $arn,
    region: $region,
    profile: $profile,
    permission_probe: {
      "cost-explorer": $ce,
      "cost-optimization-hub": $coh,
      "compute-optimizer": $co,
      "trusted-advisor": $ta,
      "ec2": $ec2,
      "organizations": $org,
      "resource-tagging": $tag
    }
  }'
