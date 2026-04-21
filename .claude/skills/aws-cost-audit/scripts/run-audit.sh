#!/usr/bin/env bash
#
# run-audit.sh — orchestrate the full AWS cost audit.
#
# Usage:
#   run-audit.sh [--profile <p>] [--output-dir <path>]
#                [--yes] [--no-deep-dives] [--all] [--skip <stage,...>]
#
# Stages:
#   auth, snapshot, waste, optimizer, data_transfer, tagging, anomalies
#
# Default flow: auth → snapshot → waste → optimizer, then prompt for the
# optional deep-dive stages.
#
# Total CE spend (default path): ~$0.10-0.12.
# Total CE spend (--all):        ~$0.20-0.30.

set -euo pipefail

PROFILE=""
OUT_DIR="reports"
YES=0
NO_DEEP=0
ALL=0
SKIP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)       PROFILE="$2"; shift 2 ;;
    --output-dir)    OUT_DIR="$2"; shift 2 ;;
    --yes|-y)        YES=1; shift ;;
    --no-deep-dives) NO_DEEP=1; shift ;;
    --all)           ALL=1; shift ;;
    --skip)          SKIP="$2"; shift 2 ;;
    -h|--help)       sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SKILLS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT_DIR"

TS_FULL=$(date -u +%Y-%m-%d-%H%M%SZ)
TS=$(date -u +%Y-%m-%d)
AUDIT_JSON="$OUT_DIR/$TS-audit.json"
AUDIT_MD="$OUT_DIR/$TS-audit.md"

skip_stage() {
  [[ -z "$SKIP" ]] && return 1
  IFS=',' read -ra arr <<<"$SKIP"
  for s in "${arr[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

confirm() {
  [[ "$YES" == "1" ]] && return 0
  local msg="$1"
  read -r -p "$msg [y/N] " ans < /dev/tty
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

common_args=(--profile "$PROFILE" --output-dir "$OUT_DIR")

log_step() { echo; echo "============================"; echo "$1"; echo "============================"; }

# ---- Stage 1: auth ----
if skip_stage "auth"; then
  auth='{}'
else
  log_step "[1/7] Verifying credentials…"
  auth=$(bash "$SKILLS_DIR/aws-auth-setup/scripts/verify-creds.sh" --profile "$PROFILE")
fi

account=$(jq -r '.account_id // "unknown"' <<<"$auth")
alias_=$(jq -r '.account_alias // ""' <<<"$auth")
ce_status=$(jq -r '.permission_probe."cost-explorer" // "unknown"' <<<"$auth")

if [[ "$ce_status" != "ok" ]]; then
  echo "FATAL: Cost Explorer permission failed ($ce_status)." >&2
  echo "See .claude/skills/aws-auth-setup/references/iam-policy.json" >&2
  exit 1
fi

# ---- Stage 2: snapshot ----
if skip_stage "snapshot"; then
  snap='{}'
else
  log_step "[2/7] Cost snapshot (~$0.05-0.08)…"
  confirm "Proceed with cost snapshot? (~\$0.05-0.08 CE)" || { echo "aborted"; exit 0; }
  snap=$(bash "$SKILLS_DIR/aws-cost-snapshot/scripts/snapshot.sh" \
    "${common_args[@]}" --forecast --by-account 2>/dev/null | jq '.' || echo '{}')
fi

# ---- Stage 3: waste hunter ----
if skip_stage "waste"; then
  waste='{}'
else
  log_step "[3/7] Waste hunter (free — no CE calls)…"
  waste=$(bash "$SKILLS_DIR/aws-waste-hunter/scripts/run-all.sh" \
    "${common_args[@]}" 2>/dev/null | jq '.' || echo '{}')
fi

# ---- Stage 4: optimizer ----
if skip_stage "optimizer"; then
  opt='{}'
else
  log_step "[4/7] Cost optimizer (Compute Optimizer + COH + TA + SP/RI utilization, ~$0.02)…"
  opt=$(bash "$SKILLS_DIR/aws-cost-optimizer/scripts/run-all.sh" \
    "${common_args[@]}" 2>/dev/null | jq '.' || echo '{}')
fi

# ---- Stage 5: optional deep-dives ----
dt='{}' ; tag='{}' ; anom='{}'

run_deep() {
  if [[ "$ALL" == "1" ]]; then return 0; fi
  if [[ "$NO_DEEP" == "1" ]]; then return 1; fi
  confirm "Run optional deep-dive stages (data-transfer, tagging, anomalies)? (~\$0.12)"
}

if ! skip_stage "data_transfer" && run_deep; then
  log_step "[5a/7] Data-transfer profiler (~$0.01)…"
  dt=$(bash "$SKILLS_DIR/aws-data-transfer-profiler/scripts/profile-transfer.sh" \
    "${common_args[@]}" --days 30 2>/dev/null | jq '.' || echo '{}')
fi

if ! skip_stage "tagging" && run_deep; then
  log_step "[5b/7] Tagging audit (~$0.04)…"
  tag=$(bash "$SKILLS_DIR/aws-tagging-audit/scripts/tagging-audit.sh" \
    "${common_args[@]}" 2>/dev/null | jq '.' || echo '{}')
fi

if ! skip_stage "anomalies" && run_deep; then
  log_step "[5c/7] Anomaly detection review (~$0.03)…"
  anom=$(bash "$SKILLS_DIR/aws-cost-anomalies/scripts/anomalies.sh" \
    "${common_args[@]}" 2>/dev/null | jq '.' || echo '{}')
fi

# ---- Stage 6: synthesize headline ----
log_step "[6/7] Consolidating findings…"

monthly=$(jq '.month_to_date.amount // 0' <<<"$snap")
mom_delta=$(jq '.mom_pacing_pct // 0' <<<"$snap")
waste_total=$(jq '.summary.total_est_monthly_cost_usd // 0' <<<"$waste")
opt_total=$(jq '.total_estimated_monthly_savings_usd // 0' <<<"$opt")
dt_total=$(jq '.total_data_transfer_cost_usd // 0' <<<"$dt")

savings_total=$(awk "BEGIN { printf \"%.2f\", $waste_total + $opt_total }")

headline=$(jq -n \
  --argjson monthly "$monthly" \
  --argjson mom "$mom_delta" \
  --argjson waste "$waste_total" \
  --argjson opt "$opt_total" \
  --argjson dt_total "$dt_total" \
  --argjson savings "$savings_total" \
  '{
    monthly_spend_usd: $monthly,
    mom_delta_pct: $mom,
    estimated_monthly_savings_identified: $savings,
    waste_monthly_usd: $waste,
    optimizer_monthly_savings_usd: $opt,
    data_transfer_monthly_usd: $dt_total
  }')

# Build top opportunities list across all sources
top=$(jq -n \
  --argjson waste "$waste" \
  --argjson opt "$opt" \
  '[
    ($waste.findings // [] | sort_by(-.est_monthly_cost_usd) | .[0:5] | map({
      source: "waste-hunter",
      action: .recommendation,
      resource: .resource_id,
      savings_monthly: .est_monthly_cost_usd
    })),
    ($opt.ranked_opportunities // [] | .[0:10] | map({
      source: .source,
      action: (.action_type + " " + (.resource_type // "")),
      resource: .resource_id,
      savings_monthly: .estimated_monthly_savings
    }))
  ] | flatten | sort_by(-.savings_monthly) | .[0:10]')

# ---- Write the consolidated JSON ----
jq -n \
  --arg run "$TS_FULL" \
  --argjson auth "$auth" \
  --argjson snap "$snap" \
  --argjson waste "$waste" \
  --argjson opt "$opt" \
  --argjson dt "$dt" \
  --argjson tag "$tag" \
  --argjson anom "$anom" \
  --argjson headline "$headline" \
  --argjson top "$top" \
  '{
    run_id: $run,
    account: { id: $auth.account_id, alias: $auth.account_alias, arn: $auth.user_arn, region: $auth.region },
    stages: {
      auth: $auth,
      snapshot: $snap,
      waste: $waste,
      optimizer: $opt,
      data_transfer: $dt,
      tagging: $tag,
      anomalies: $anom
    },
    headline: ($headline + { top_opportunities: $top })
  }' > "$AUDIT_JSON"

# ---- Markdown render ----
bash "$(dirname "$0")/render-audit.sh" "$AUDIT_JSON" > "$AUDIT_MD"

log_step "[7/7] Done."
echo
echo "JSON bundle : $AUDIT_JSON"
echo "Markdown    : $AUDIT_MD"
echo
echo "Headline:"
jq -r '
  def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
  "  Account:           \(.account.id) (\(.account.alias // "no alias"))",
  "  Month-to-date:     \(.headline.monthly_spend_usd | fmt)",
  "  MoM pacing:        \(.headline.mom_delta_pct)%",
  "  Waste (list price): \(.headline.waste_monthly_usd | fmt)/mo",
  "  Optimizer savings:  \(.headline.optimizer_monthly_savings_usd | fmt)/mo",
  "  Total identified:   \(.headline.estimated_monthly_savings_identified | fmt)/mo"
' "$AUDIT_JSON"
