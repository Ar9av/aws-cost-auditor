---
name: aws-cost-snapshot
description: Produce a high-level AWS spend snapshot — current MTD, previous month, top services, MoM trend, 30-day forecast, and linked-account breakdown (if Organizations access is available). Use this skill when the user asks "what's my AWS bill", "how much are we spending", "where's the money going", for a first-look or executive-summary view, or as the opening step of a full audit. Stays cheap: ~5-8 Cost Explorer API calls per run (~$0.05-0.08).
license: MIT
metadata:
  author: Ar9av
  version: "1.1.0"
---

# aws-cost-snapshot

The fastest, cheapest way to answer "where's the money going?" Runs a fixed
set of Cost Explorer queries that together tell you:

1. Month-to-date spend and where it's pacing vs. last month.
2. The top 10 services by spend this month, with MoM delta %.
3. The daily spend curve for the last 60 days (detects ramps/spikes at a glance).
4. A 30-day forecast at 80% confidence.
5. Per-linked-account breakdown (if this is a management account).

## When to invoke

- User asks any variant of:
  - "What's my AWS bill this month?"
  - "How much are we spending on AWS?"
  - "Give me a cost overview."
  - "Is spend going up?"
- First step of a full audit — before drilling in, you need the landscape.
- Sanity-check after making an architectural change — did the bill move?

## When NOT to invoke

- User asks about a specific resource, service, or hidden cost → use
  `aws-cost-deep-dive` or `aws-data-transfer-profiler`.
- User asks for orphans / idle resources → use `aws-waste-hunter` (no CE
  calls, faster).
- User asks about cost spikes / anomalies → use `aws-cost-anomalies`.

## Cost of running this skill

Baseline run: **~5 CE API calls = $0.05**.

With `--by-account` on a management account: +1 call = $0.06.
With `--forecast`: +1 call = $0.06.
With `--daily` series: +1 call. Total range **$0.05 - $0.08**.

No hourly granularity used (that's $0.01/request + $0.00000033/record).

## How to run

```bash
# Default: month-to-date + previous month + top services + 60-day daily series
bash .claude/skills/aws-cost-snapshot/scripts/snapshot.sh \
  --profile cost-audit

# With forecast and linked-account breakdown
bash .claude/skills/aws-cost-snapshot/scripts/snapshot.sh \
  --profile cost-audit --forecast --by-account
```

Output lands in `reports/YYYY-MM-DD-snapshot.json` and a human-readable
summary is printed to stdout.

## What to do with the output

Look at:

- **Top 3 services.** They almost always account for >60% of spend. Any
  deep-dive worth doing starts there.
- **MoM delta.** Any service growing >20% MoM without a known cause is a
  candidate for `aws-cost-anomalies` → `aws-cost-deep-dive`.
- **Forecast > budget.** If the 30-day forecast exceeds what the user
  expects, ask what their budget is and recommend `aws-waste-hunter` +
  `aws-cost-optimizer`.
- **Data Transfer line item.** If "Data Transfer" or "EC2-Other" shows up
  in the top 5, that's almost always NAT Gateway / cross-AZ traffic →
  route to `aws-data-transfer-profiler`.

## Output contract (reports/YYYY-MM-DD-snapshot.json)

```json
{
  "account_id": "...",
  "currency": "USD",
  "month_to_date": { "amount": 12345.67, "days_elapsed": 14 },
  "previous_month": { "amount": 23456.78 },
  "mom_pacing_pct": 5.2,
  "top_services": [
    { "service": "Amazon Elastic Compute Cloud - Compute",
      "mtd": 4500.00, "prev_month": 4200.00, "mom_delta_pct": 7.1 }
    ...
  ],
  "daily_series_60d": [ { "date": "2026-02-20", "amount": 765.43 }, ... ],
  "forecast_next_30d": { "amount": 24800.00, "confidence_interval": [23400, 26200] },
  "by_account": [ { "account_id": "...", "mtd": 5432.10 } ],
  "meta": { "ce_api_calls": 7, "estimated_cost_usd": 0.07 }
}
```

## Why these specific metrics

- **MTD vs. prev month** is the single strongest first signal. "We spent
  $X last month, we're at $Y this month with Z days left, so pacing is A%."
- **60-day daily series** surfaces step changes — a new deployment, a cron
  that started looping, a retention policy that stopped working.
- **Top-10 services** is narrow enough to read out loud but wide enough
  to catch the long-tail problem (e.g., a rogue Elasticsearch domain).
- **Forecast** uses `ce:GetCostForecast` which is Amazon's own ML model;
  cheaper than calculating trendline ourselves and accounts for seasonality.

## Common gotchas

- The **current day is excluded** from MTD because Cost Explorer hasn't
  finalized today's data yet.
- Costs include **credits and refunds** by default (UnblendedCost). If the
  user expects to see what they'd owe without credits, rerun with
  `--metric NetUnblendedCost`.
- `Amazon Elastic Compute Cloud - Compute` and `EC2 - Other` are different
  line items — the first is instance-hours, the second is EBS, data
  transfer, and snapshot costs rolled into EC2. Don't merge them.
