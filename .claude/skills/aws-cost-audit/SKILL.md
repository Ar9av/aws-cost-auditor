---
name: aws-cost-audit
description: Top-level orchestrator for a full AWS cost audit. Sequences aws-auth-setup → aws-cost-snapshot → aws-waste-hunter → aws-cost-optimizer → aws-data-transfer-profiler → aws-tagging-audit → aws-cost-anomalies with confirmation gates between each stage. Use this skill when the user asks for "a full audit", "audit my AWS costs", "comprehensive cost review", "FinOps review", or any variant that implies wanting the whole picture rather than one specific question. Produces a consolidated markdown report.
license: MIT
metadata:
  author: Ar9av
  version: "1.1.0"
---

# aws-cost-audit

The headline skill. Runs every other skill in the pack in the right
order, respecting cost gates, and produces one consolidated report at
the end. Think of it as a FinOps analyst's two-hour pass, compressed
into a scripted workflow.

## When to invoke

- User asks for "a full audit", "comprehensive review", "FinOps
  review", "the works".
- User is new to the account and wants the big picture.
- Periodic review (monthly / quarterly).

## When NOT to invoke

- User has a specific question ("why is S3 expensive") → route to the
  single matching skill instead.
- First-time setup where creds aren't configured → just run
  `aws-auth-setup` alone; the orchestrator also starts there but
  suggesting just the auth skill avoids noise.

## The audit flow

```
┌─────────────────────┐
│ 1. aws-auth-setup   │  Verify creds, permission probe. Stop on any
│                     │  AccessDenied; route user to fix policy.
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│ 2. aws-cost-snapshot│  Cheap overview ($0.05). Establishes top
│                     │  services and MoM movement.
└──────────┬──────────┘
           ▼
  [GATE: confirm continue]
           ▼
┌─────────────────────┐
│ 3. aws-waste-hunter │  Free. Quick wins. Runs in parallel per-region.
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│ 4. aws-cost-optimizer│  Free (COH/CO/TA) + $0.02 SP/RI. AWS's own
│                     │  rightsizing + commitment advice.
└──────────┬──────────┘
           ▼
  [GATE: does user want to dig into data transfer / tagging /
         anomalies? Those are optional deep-dives.]
           ▼
┌─────────────────────┐      ┌──────────────────────────┐    ┌──────────────┐
│ 5a. aws-data-       │      │ 5b. aws-tagging-audit    │    │ 5c. aws-cost-│
│     transfer-       │      │                          │    │    anomalies │
│     profiler        │      │                          │    │              │
└──────────┬──────────┘      └──────────┬───────────────┘    └──────┬───────┘
           │                            │                           │
           ▼                            ▼                           ▼
   [~$0.06]                     [~$0.04]                    [~$0.03]
           └────────────┬───────────────┴─────────────────────────┘
                        ▼
          ┌─────────────────────────────┐
          │ 6. Consolidated report      │
          │    reports/YYYY-MM-DD-      │
          │    audit.md                 │
          └─────────────────────────────┘
```

## Cost gates

Before any stage that spends >$0.05 on Cost Explorer, the orchestrator
prints the estimated spend and asks for confirmation. The default-path
audit is **~$0.10-0.25 in CE charges** end-to-end.

On Enterprise / Business+ accounts, add Trusted Advisor: free for the
API but assumes the support plan is already paid for.

## How to run

```bash
# Full audit, interactive gates
bash .claude/skills/aws-cost-audit/scripts/run-audit.sh \
  --profile cost-audit

# Non-interactive: skip optional stages 5a-5c
bash .claude/skills/aws-cost-audit/scripts/run-audit.sh \
  --profile cost-audit --no-deep-dives --yes

# Include everything, no prompts (run on a cron, say)
bash .claude/skills/aws-cost-audit/scripts/run-audit.sh \
  --profile cost-audit --all --yes
```

## How to invoke from Claude Code

The agent should:

1. Verify credentials first with `aws-auth-setup` — show the user which
   account and permissions are in play.
2. Ask the user whether they want the full audit (all stages) or a
   targeted one — don't assume.
3. If full: run the orchestrator script with `--yes` and report each
   stage's headline finding as it completes.
4. If targeted: route to the single appropriate skill.
5. At the end, show the consolidated markdown report and ask if the
   user wants to act on any specific finding (which would be a separate
   remediation conversation with separate permissions).

## Output

- `reports/YYYY-MM-DD-audit.md` — consolidated human-readable report
  with findings grouped by theme and ranked by estimated monthly savings.
- `reports/YYYY-MM-DD-audit.json` — full machine-readable bundle
  containing every stage's raw output.

## Output structure

```json
{
  "run_id": "2026-04-22-093012Z",
  "account": { "id": "...", "alias": "..." },
  "stages": {
    "auth":        { "status": "ok", "permission_probe": {...} },
    "snapshot":    { ... },
    "waste":       { ... },
    "optimizer":   { ... },
    "data_transfer": { ... },
    "tagging":     { ... },
    "anomalies":   { ... }
  },
  "headline": {
    "monthly_spend_usd": 24800,
    "mom_delta_pct": 5.2,
    "estimated_monthly_savings_identified": 6420,
    "top_opportunities": [
      { "source": "waste-hunter", "action": "Delete 14 unattached EBS volumes", "savings_monthly": 480 },
      { "source": "optimizer", "action": "Rightsize 6 EC2 instances to Graviton", "savings_monthly": 920 },
      { "source": "data-transfer", "action": "Create Gateway VPC Endpoint for S3 in us-east-1", "savings_monthly": 640 }
    ]
  },
  "total_ce_api_calls": 14,
  "total_estimated_audit_cost_usd": 0.14
}
```

## Notes for the agent

- **Don't surface raw JSON to the user.** Render each stage's summary
  in markdown.
- **Surface gaps, not just findings.** If Cost Optimization Hub isn't
  enrolled, say so — enrolling takes one click and doubles the
  recommendation pool.
- **Keep the "headline" under 5 bullets.** The user can drill into any
  of them; the first pass should be scannable in 30 seconds.
- **Quote the generated report path at the end** so the user can open
  it themselves.
