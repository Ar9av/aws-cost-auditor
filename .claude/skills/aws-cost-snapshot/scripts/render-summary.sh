#!/usr/bin/env bash
#
# render-summary.sh — pretty-print a snapshot JSON to markdown on stdout.
#
# Usage: render-summary.sh <path-to-snapshot.json>

set -euo pipefail

FILE="${1:?usage: render-summary.sh <snapshot.json>}"

jq -r '
  def fmt: "$" + (. | tonumber | . * 100 | round / 100 | tostring);
  def pct: if . == null then "n/a" else (tostring + "%") end;

  "# AWS Cost Snapshot — " + .account_id,
  "",
  "Currency: " + .currency + "  ·  Metric: " + .metric,
  "",
  "## Totals",
  "",
  "| Period | Amount |",
  "|---|---|",
  "| Month to date (" + .month_to_date.period.start + " → " + .month_to_date.period.end + ") | " + (.month_to_date.amount | fmt) + " |",
  "| Previous month | " + (.previous_month.amount | fmt) + " |",
  "| MoM pacing | " + (.mom_pacing_pct // 0 | (. * 10 | round) / 10 | pct) + " |",
  (if .forecast_next_30d then
    "| Forecast (next 30d) | " + (.forecast_next_30d.amount | fmt) + " |"
   else empty end),
  "",
  "## Top services this month",
  "",
  "| Service | MTD | Prev month | MoM Δ |",
  "|---|---:|---:|---:|",
  (.top_services[] |
    "| " + .service + " | " + (.mtd | fmt) + " | " +
    (.prev_month | fmt) + " | " +
    (.mom_delta_pct // 0 | (. * 10 | round) / 10 | pct) + " |"),
  "",
  (if .by_account and (.by_account | type == "array") then
    ("## Linked accounts\n\n| Account | MTD |\n|---|---:|\n" +
     (.by_account | map("| " + .account_id + " | " + (.mtd | fmt) + " |") | join("\n")))
   else empty end),
  "",
  "_CE API calls: \(.meta.ce_api_calls)  ·  est. cost: $\(.meta.estimated_cost_usd)_"
' "$FILE"
