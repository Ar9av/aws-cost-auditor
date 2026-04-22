#!/usr/bin/env bash
#
# run-all.sh — run every waste check and merge into one report.
#
# Usage: run-all.sh [--profile <p>] [--regions <r1,r2>]
#                   [--skip <check1,check2>]
#                   [--output-dir <path>] [--human]

set -euo pipefail

PROFILE=""
REGIONS=""
SKIP=""
OUT_DIR="reports"
HUMAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    PROFILE="$2"; shift 2 ;;
    --regions)    REGIONS="$2"; shift 2 ;;
    --skip)       SKIP="$2"; shift 2 ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --human)      HUMAN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-waste-audit.json"

CHECKS=(
  "ebs-unattached"
  "eips-unused"
  "nat-idle"
  "elbs-idle"
  "ec2-stopped"
  "snapshots-old"
  "cw-logs-noretention"
  "rds-idle"
  "ecr-empty"
  "target-groups-empty"
)

skip_check() {
  [[ -z "$SKIP" ]] && return 1
  IFS=',' read -ra arr <<<"$SKIP"
  for s in "${arr[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

all_findings="[]"

for check in "${CHECKS[@]}"; do
  if skip_check "$check"; then
    echo "skipping $check" >&2
    continue
  fi
  script="$here/$check.sh"
  if [[ ! -x "$script" ]]; then
    echo "missing script: $script" >&2
    continue
  fi
  echo "== running $check ==" >&2
  args=(--profile "$PROFILE" --output-dir "$OUT_DIR")
  [[ -n "$REGIONS" ]] && args+=(--regions "$REGIONS")
  if result=$(bash "$script" "${args[@]}" 2>>/tmp/waste-hunter-errors.log); then
    all_findings=$(jq --argjson a "$all_findings" --argjson b "$result" '$a + $b' <<<"null")
  else
    echo "check $check failed (see /tmp/waste-hunter-errors.log)" >&2
  fi
done

# Summarize
summary=$(jq '
  {
    total_findings: length,
    total_est_monthly_cost_usd: ([.[].est_monthly_cost_usd] | add | . * 100 | round / 100),
    by_check: (group_by(.check) | map({
      check: .[0].check,
      count: length,
      est_monthly_cost_usd: ([.[].est_monthly_cost_usd] | add | . * 100 | round / 100)
    }) | sort_by(-.est_monthly_cost_usd)),
    by_region: (group_by(.region) | map({
      region: .[0].region,
      count: length,
      est_monthly_cost_usd: ([.[].est_monthly_cost_usd] | add | . * 100 | round / 100)
    }) | sort_by(-.est_monthly_cost_usd))
  }' <<<"$all_findings")

jq -n \
  --argjson summary "$summary" \
  --argjson findings "$all_findings" \
  '{
    generated_at: (now | todate),
    summary: $summary,
    findings: $findings
  }' > "$OUT_JSON"

echo "Wrote $OUT_JSON" >&2

if [[ "$HUMAN" == "1" ]]; then
  jq -r '
    def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
    "# AWS Waste Audit — \(.generated_at)",
    "",
    "Total findings: \(.summary.total_findings)  ·  Estimated monthly waste: \(.summary.total_est_monthly_cost_usd | fmt) (list price)",
    "",
    "## By check",
    "| Check | Count | Est monthly |",
    "|---|---:|---:|",
    (.summary.by_check[] | "| \(.check) | \(.count) | \(.est_monthly_cost_usd | fmt) |"),
    "",
    "## By region",
    "| Region | Count | Est monthly |",
    "|---|---:|---:|",
    (.summary.by_region[] | "| \(.region) | \(.count) | \(.est_monthly_cost_usd | fmt) |"),
    "",
    "## Top 20 findings by cost",
    "",
    "| Check | Region | Resource | Est $/mo | Recommendation |",
    "|---|---|---|---:|---|",
    (.findings | sort_by(-.est_monthly_cost_usd) | .[0:20][] |
      "| \(.check) | \(.region) | `\(.resource_id)` | \(.est_monthly_cost_usd | fmt) | \(.recommendation) |")
  ' "$OUT_JSON"
else
  cat "$OUT_JSON"
fi
