---
name: aws-cost-optimizer
description: Pull cost-saving recommendations from AWS's own optimization services — Cost Optimization Hub (aggregator), Compute Optimizer (EC2/EBS/Lambda/RDS/ECS rightsizing), Trusted Advisor (Business Support+ only), and current Savings Plan / Reserved Instance utilization. Use this skill when the user asks "what should I change", "how do I save money", "rightsize recommendations", "Savings Plans", "reserved instances", "what does AWS recommend". Gracefully degrades when Cost Optimization Hub or Trusted Advisor isn't enrolled / available.
license: MIT
metadata:
  author: Ar9av
  version: "1.1.0"
---

# aws-cost-optimizer

Gets AWS's *own* opinion on what you should change. Three data sources,
priced from best-to-worst in that order:

1. **Cost Optimization Hub** — the aggregator. Deduplicates and ranks
   recommendations from all the sources below + RI/SP purchase advice,
   with a single savings estimate per recommendation. **Must be enrolled
   once per account** in the Billing console (Cost Optimization Hub →
   Preferences → Opt in). Free to use the API.
2. **Compute Optimizer** — rightsizing for EC2, EBS, Lambda, ECS-on-Fargate,
   Auto Scaling groups, and (Dec 2023+) RDS. Needs ≥14 days of
   utilization data. Free.
3. **Trusted Advisor** — cost checks (idle instances, unused EIPs, etc.).
   **Requires Business Support+.** Free to use the API once you have
   the plan. On Basic/Developer plans, you only get the 7 basic checks
   via the console.

## When to invoke

- User asks what to change, rightsize, commit, or purchase.
- User mentions "Savings Plans", "Reserved Instances", "RI coverage",
  "SP utilization".
- After `aws-cost-snapshot` / `aws-cost-deep-dive` identifies expensive
  EC2, RDS, Lambda, or EBS spend.
- As the recommendation pass within a full audit.

## When NOT to invoke

- User wants orphaned / idle resources → `aws-waste-hunter` is both
  faster and more detailed for that specific case (COH / TA both
  return some of the same waste findings, but the hunter crawls every
  region and gives precise resource IDs).
- User wants to understand spend patterns → `aws-cost-deep-dive`.

## How to run

```bash
# Full optimization scan (all three sources + SP/RI utilization)
bash .claude/skills/aws-cost-optimizer/scripts/run-all.sh \
  --profile cost-audit

# Just Cost Optimization Hub (best single source)
bash .claude/skills/aws-cost-optimizer/scripts/cost-optimization-hub.sh \
  --profile cost-audit

# Just Compute Optimizer for EC2
bash .claude/skills/aws-cost-optimizer/scripts/compute-optimizer.sh \
  --profile cost-audit --resource-type Ec2Instance

# Current SP/RI utilization (useful for "am I using what I bought?")
bash .claude/skills/aws-cost-optimizer/scripts/sp-ri-utilization.sh \
  --profile cost-audit
```

## Cost of running

All the optimization APIs above are **free**. `sp-ri-utilization.sh` uses
`ce:GetSavingsPlansUtilization` and `ce:GetReservationUtilization` —
that's **2 CE calls = $0.02**.

## Graceful degradation

The scripts detect and report these states instead of failing hard:

| State | Behavior |
|---|---|
| Cost Optimization Hub not enrolled | Skip COH, call Compute Optimizer and TA directly; note in report. |
| Compute Optimizer not enrolled | Emit guidance to enrol (console or CLI); skip. |
| Trusted Advisor `SubscriptionRequiredException` | Skip TA; note that Business Support+ is needed. |
| No RIs / SPs purchased | Return zero in utilization block; no error. |

## Output contract

```json
{
  "account_id": "...",
  "sources": {
    "cost_optimization_hub": { "enrolled": true, "recommendations": [...] },
    "compute_optimizer":     { "enrolled": true, "summary": {...}, "by_resource_type": {...} },
    "trusted_advisor":       { "available": true, "checks": [...] },
    "sp_ri_utilization":     { "savings_plans": {...}, "reservations": {...} }
  },
  "ranked_opportunities": [
    {
      "source": "cost-optimization-hub",
      "action_type": "Rightsize",
      "resource_type": "Ec2Instance",
      "resource_id": "i-0abc...",
      "current_monthly": 240.00,
      "recommended_monthly": 120.00,
      "estimated_monthly_savings": 120.00,
      "implementation_effort": "Low",
      "restart_needed": false,
      "rationale": "Current utilization 8% CPU peak; recommend m7g.large."
    }
  ],
  "total_estimated_monthly_savings_usd": 4200.00
}
```

## Interpreting

1. **Stack-rank by savings, not source.** COH already does this for its
   own recommendations; the `run-all` script extends the ranking across
   Compute Optimizer and TA findings so everything lives in one list.
2. **Ignore "very low risk" wins at the bottom.** A $2/mo savings with
   "restart required" isn't worth the change-management cost — note
   the long tail exists but don't act on each item.
3. **Savings Plan / RI utilization below 90%** is a yellow flag. Below
   80% and you're effectively paying on-demand plus the commitment.
4. **Restart-required rightsizings** — batch them into a single
   maintenance window rather than doing them individually.

## Further reading

- `references/recommendations-reference.md` — how each field maps to
  the underlying AWS API surface.
- `references/sp-vs-ri.md` — cheat-sheet on when Savings Plans beat
  Reserved Instances and vice-versa.
