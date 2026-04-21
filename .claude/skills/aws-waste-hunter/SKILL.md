---
name: aws-waste-hunter
description: Scan all AWS regions for orphaned, idle, and over-retained resources that silently accrue cost — unattached EBS volumes, unused Elastic IPs, idle NAT Gateways, load balancers with zero targets, old EBS snapshots, CloudWatch log groups with no retention, unused RDS instances, stopped EC2 with attached EBS, and empty ECR repositories. Use this skill whenever the user asks "what's wasted", "what can we delete", "find idle resources", "cleanup opportunities", or after `aws-cost-snapshot` as a quick wins pass. Uses only free Describe/List APIs — no Cost Explorer cost.
---

# aws-waste-hunter

Finds resources that are almost certainly costing money for nothing.
Everything here uses free `Describe*` / `List*` APIs — **no Cost Explorer
charges**. This is the fastest high-ROI pass in the auditor.

## When to invoke

- User asks "what's wasted", "what can I delete", "find idle resources",
  "any cleanup opportunities".
- After a snapshot run, as the next suggested step for quick wins.
- Before year-end / quarterly budget reviews.
- In response to an unexplained bill increase — often new waste appeared.

## What it scans (by default, all regions, all checks)

| Check | Scripts | Signal |
|---|---|---|
| Unattached EBS volumes | `ebs-unattached.sh` | Volume `State=available`. |
| Unused Elastic IPs | `eips-unused.sh` | EIP with no `AssociationId`. |
| Idle NAT Gateways | `nat-idle.sh` | NAT with `<1MB` bytes processed / 14d (CloudWatch). |
| Zombie load balancers | `elbs-idle.sh` | ELB with 0 healthy targets, or 0 requests / 14d. |
| Stopped EC2 (EBS still billing) | `ec2-stopped.sh` | Instance `stopped` for >30d — EBS still charged. |
| Old EBS snapshots | `snapshots-old.sh` | Snapshot >180d, volume gone OR not tagged for retention. |
| CW log groups without retention | `cw-logs-noretention.sh` | `retentionInDays=null`. |
| Unused RDS instances | `rds-idle.sh` | DB Connections=0 for 14d (CloudWatch). |
| Empty ECR repositories | `ecr-empty.sh` | Repo with 0 images and >30d old. |
| Orphan target groups | `target-groups-empty.sh` | Target group with no registered targets. |

Master script `run-all.sh` orchestrates all of them in parallel per-region.

## When NOT to invoke

- User asks about cost breakdown → that's `aws-cost-snapshot` /
  `aws-cost-deep-dive`, not waste.
- User wants rightsizing recommendations → `aws-cost-optimizer` (it
  distinguishes between "too big" and "entirely unused").
- User asks about tagging → `aws-tagging-audit`.

## How to run

```bash
# All checks, all regions (default: only regions with any resources)
bash .claude/skills/aws-waste-hunter/scripts/run-all.sh \
  --profile cost-audit

# One check only
bash .claude/skills/aws-waste-hunter/scripts/ebs-unattached.sh \
  --profile cost-audit --region us-east-1

# Specific region set
bash .claude/skills/aws-waste-hunter/scripts/run-all.sh \
  --profile cost-audit --regions us-east-1,us-west-2,eu-west-1
```

## Cost estimation

Each finding comes with a **list-price monthly cost** computed from
published AWS pricing. These are estimates — actual billing depends on
Savings Plans, RIs, private pricing, and tiering. The report always
annotates amounts as "list price, pre-discount."

Reference prices baked into the scripts (us-east-1, April 2026):

| Resource | Assumed list price |
|---|---|
| EBS gp3 volume | $0.08/GB-month |
| EBS gp2 volume | $0.10/GB-month |
| EBS io2 volume | $0.125/GB-month + IOPS |
| EBS snapshot | $0.05/GB-month (standard tier) |
| Unassociated EIP | $3.60/month ($0.005/h) |
| NAT Gateway (idle) | $32.85/month hourly only |
| Classic ELB | $16.43/month hourly |
| ALB/NLB | $16.43/month hourly + LCU |
| CloudWatch Logs retained forever | $0.03/GB-month |

For non-us-east-1, the scripts multiply by a rough regional factor. See
`references/pricing-factors.md`.

## Output

Each script emits a JSON array of findings to
`reports/YYYY-MM-DD-waste-<check>-<region>.json`. `run-all.sh` merges all
of them into a single `reports/YYYY-MM-DD-waste-audit.json` plus a
human-readable `.md` summary.

Finding schema:

```json
{
  "check": "ebs-unattached",
  "region": "us-east-1",
  "resource_id": "vol-0abc...",
  "resource_type": "ec2:volume",
  "evidence": { "state": "available", "size_gb": 500, "created": "2025-08-14" },
  "est_monthly_cost_usd": 40.00,
  "recommendation": "Delete or snapshot-and-delete. Volume has been detached for 74 days."
}
```

## Interpreting findings

- **"Detached EBS >14 days"** is almost always safe to delete-after-snapshot.
- **"NAT Gateway idle"** can be a deployment artifact. Confirm VPC still
  has workloads routing to it.
- **"Stopped EC2 >30 days"** — the instance runs $0/hour but attached EBS
  keeps billing. Either terminate or remove volumes.
- **"Log group with no retention"** doesn't directly mean waste, but it
  means costs will grow forever. Flag as a policy gap.
- **"ALB with 0 healthy targets"** — the ALB is billing $16/mo for
  nothing. Might be a transient deploy state; double-check with the user.

## Remediation guidance

This skill is **detection only**. It produces a list; it never mutates.
The recommendation field gives a suggested action, and the user (or a
separate write-capable tooling pass) executes it.

For remediation patterns, see `references/remediation-guidance.md`.
