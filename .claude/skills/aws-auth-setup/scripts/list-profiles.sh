#!/usr/bin/env bash
#
# list-profiles.sh — show configured AWS profiles and which ones are SSO.
#
# Usage: list-profiles.sh

set -euo pipefail

if ! command -v aws >/dev/null; then
  echo "FATAL: aws CLI not installed" >&2
  exit 1
fi

CREDS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
CONFIG_FILE="${AWS_CONFIG_FILE:-$HOME/.aws/config}"

profiles=$(aws configure list-profiles 2>/dev/null || true)
if [[ -z "$profiles" ]]; then
  echo "No AWS profiles configured."
  echo "To create one:  aws configure --profile cost-audit"
  echo "For SSO:        aws configure sso --profile cost-audit-sso"
  exit 0
fi

echo "Configured profiles:"
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  kind="static"
  if [[ -f "$CONFIG_FILE" ]] && grep -qE "^\[profile $p\]" "$CONFIG_FILE" && \
     grep -A20 "^\[profile $p\]" "$CONFIG_FILE" | grep -qE "^sso_"; then
    kind="sso"
  fi
  region=$(aws configure get region --profile "$p" 2>/dev/null || echo "-")
  echo "  - $p  (kind=$kind, region=$region)"
done <<<"$profiles"
