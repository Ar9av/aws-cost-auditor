---
name: aws-cost-anomalies
description: Surface AWS Cost Anomaly Detection findings. Lists anomaly monitors, recent anomalies with impact, and root causes identified by AWS's ML model. Use this skill when the user asks "is there a cost spike", "why did the bill jump", "anomaly alerts", "unexpected charges", or when `aws-cost-snapshot` shows an unusual MoM jump. Also surfaces when no monitors are configured (gap signal).
---

# aws-cost-anomalies

AWS Cost Anomaly Detection is a managed ML service that watches your
spend and flags statistically unusual increases. It's free. If the user
has any unexplained bill movement, this is the first place to look —
before hand-rolling a deep-dive.

## When to invoke

- User asks about cost spikes, jumps, surprises, anomalies.
- `aws-cost-snapshot` shows an MoM delta >20% on one service.
- User sets up a new workload and wants confidence there are no cost
  surprises.
- As part of a full audit.

## When NOT to invoke

- User wants steady-state breakdown → `aws-cost-snapshot` /
  `aws-cost-deep-dive`.
- User wants a general overview → `aws-cost-snapshot`.

## What it fetches

1. **Anomaly monitors configured on this account**. If zero, strongly
   recommend enabling the default `AWS services` monitor — it's free
   and covers the whole account.
2. **Anomalies in the last 90 days** with `TotalImpact > $100` (default
   threshold — tunable with `--min-impact`). Each anomaly includes:
   - Start / end dates
   - Root-cause service, usage type, region
   - Total impact (absolute $)
   - Impact percentage vs baseline
3. **Anomaly subscriptions** — who's alerted when anomalies fire.

## Cost

2-3 CE API calls = **$0.02-0.03**.

## How to run

```bash
# Default: last 90 days, min impact $100
bash .claude/skills/aws-cost-anomalies/scripts/anomalies.sh \
  --profile cost-audit

# All anomalies, any impact
bash .claude/skills/aws-cost-anomalies/scripts/anomalies.sh \
  --profile cost-audit --min-impact 0 --days 180
```

## Output contract

```json
{
  "monitors": [ { "monitor_arn": "...", "type": "DIMENSIONAL", "dimension": "SERVICE" } ],
  "anomalies": [ {
    "anomaly_id": "...",
    "start_date": "2026-03-12", "end_date": "2026-03-14",
    "root_cause_service": "Amazon Elastic Compute Cloud - Compute",
    "root_cause_usage_type": "BoxUsage:m5.2xlarge",
    "root_cause_region": "us-east-1",
    "total_impact_usd": 842.10,
    "impact_pct": 180.5
  } ],
  "subscriptions": [ { "subscription_arn": "...", "threshold": 100, "frequency": "DAILY" } ],
  "gaps": { "no_monitors": false, "no_subscriptions": false }
}
```

## Interpreting

- **No monitors configured** → this is a gap. Recommend the default
  `aws-services` monitor; takes one API call to create.
- **Anomaly with single-service root cause** → route to
  `aws-cost-deep-dive --service <that service>`.
- **Anomaly with usage-type spike but stable service total** → something
  shifted usage mix (e.g., moved from Spot to on-demand). Flag for
  deeper look.
- **Multiple simultaneous anomalies** → often a deployment or region
  failover. Correlate with CloudTrail if needed.

## Remediation guidance

Creating / updating monitors requires `ce:CreateAnomalyMonitor` which is
**not** in this pack's read-only policy. Tell the user they'll need to
set that up once (console click or CLI with a write policy); the skill
shows them exactly what's missing.
