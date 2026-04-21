#!/usr/bin/env bash
#
# ecr-empty.sh — ECR repositories with 0 images. They're free, but they
# indicate dead projects; useful signal for broader cleanup.
# Usage: ecr-empty.sh --profile <p> [--region <r>] [--regions <r1,r2>]

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
parse_args "$@"

scan_region() {
  local region="$1"

  local repos
  repos=$(aws_ ecr describe-repositories --region "$region" \
    --query 'repositories[].{name:repositoryName,arn:repositoryArn,created:createdAt,uri:repositoryUri}' \
    2>/dev/null || echo '[]')

  while read -r r; do
    [[ -z "$r" ]] && continue
    local name
    name=$(jq -r '.name' <<<"$r")
    local cnt
    cnt=$(aws_ ecr list-images --region "$region" --repository-name "$name" \
      --query 'length(imageIds)' 2>/dev/null || echo 0)

    if [[ "$cnt" == "0" ]]; then
      finding "ecr-empty" "$region" "$name" "ecr:repository" \
        "$(jq -nc --arg name "$name" --argjson r "$r" '{name: $name, created: $r.created, image_count: 0}')" \
        0.00 \
        "Empty ECR repo — no direct cost, but usually indicates dead project. Review and delete with others."
    fi
  done < <(jq -c '.[]' <<<"$repos")
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
