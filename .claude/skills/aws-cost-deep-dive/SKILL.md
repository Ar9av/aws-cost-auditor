---
name: aws-cost-deep-dive
description: Drill into the spend for one specific AWS service or dimension. Breaks the service's cost down by usage type, region, availability zone, linked account, and (last 14 days only) resource ID. Use this skill when the user has already seen a snapshot and now asks "why is EC2 so expensive", "what's in the EC2-Other line", "where is RDS money going", or wants to target the top 1-3 services from `aws-cost-snapshot`. Costs ~$0.03-0.15 per service depending on depth.
license: MIT
metadata:
  author: Ar9av
  version: "1.1.0"
---

# aws-cost-deep-dive

Given a service name (or dimension value), this skill produces the full
answer to "why is this so expensive?" — broken down along every axis Cost
Explorer supports.

## When to invoke

- User names a specific AWS service and asks what's in it.
- Follow-up to `aws-cost-snapshot` when one service dominates spend.
- User says "break down <service>" or "drill into <service>".
- User wants resource-level attribution (the skill will warn about the
  14-day limit and the $0.01 call cost).

## When NOT to invoke

- User asks about data-transfer or NAT specifically → use
  `aws-data-transfer-profiler` (it knows the EC2-Other tricks).
- User wants untagged spend → use `aws-tagging-audit`.
- User hasn't seen totals yet → run `aws-cost-snapshot` first so we know
  which service to drill into.

## What the drill-down covers

Given `--service "Amazon Elastic Compute Cloud - Compute"` over 30 days:

1. **By usage type** (e.g., `BoxUsage:m5.xlarge`, `DataTransfer-Out-Bytes`).
   This is the single most useful dimension — it tells you what you're
   actually being charged for.
2. **By region** — spotlights multi-region sprawl.
3. **By availability zone** (optional, via `--by-az`) — for cross-AZ
   traffic hunting.
4. **By linked account** (if Organizations access).
5. **By operation** (e.g., `RunInstances`, `DescribeInstances`) — useful
   for API-priced services like S3 and DynamoDB.
6. **Optional resource-level attribution** (`--with-resources`, last 14
   days only) — this is the only way to tie charges to specific
   instance/volume/bucket IDs.

## Cost of running

| Flags | CE calls | Cost |
|---|---|---|
| default (usage-type + region + operation, 30d) | 3 | $0.03 |
| `--by-az` | +1 | +$0.01 |
| `--by-account` | +1 | +$0.01 |
| `--with-resources` (hourly, last 14d) | +1 hourly call | ~$0.02-0.05 |
| `--90d` instead of 30d | same calls, wider range | same |

Always confirm with the user before enabling `--with-resources` — it uses
hourly granularity which adds per-record charges on top of the $0.01
request fee (~$0.01 per 1,000 records).

## How to run

```bash
# Basic drill: top usage types and regions for EC2 over last 30 days
bash .claude/skills/aws-cost-deep-dive/scripts/drill-service.sh \
  --profile cost-audit \
  --service "Amazon Elastic Compute Cloud - Compute"

# Add resource-level (last 14 days, hourly granularity)
bash .claude/skills/aws-cost-deep-dive/scripts/drill-service.sh \
  --profile cost-audit \
  --service "Amazon Simple Storage Service" \
  --with-resources
```

Output: `reports/YYYY-MM-DD-deep-<service-slug>.json` + markdown summary.

## Service-specific playbooks

The full playbooks live in `references/service-playbooks.md`. Summary of
what each top service's drill-down usually reveals:

- **EC2 - Compute**: look at `BoxUsage:<type>` to see where instance-hours
  go; look at `SpotUsage:<type>` for how much is already on Spot.
- **EC2 - Other**: this is EBS (`EBS:VolumeUsage*`), snapshots
  (`EBS:SnapshotUsage`), NAT (`NatGateway-Hours`, `NatGateway-Bytes`),
  data transfer (`DataTransfer-Regional-Bytes`, `*-Out-Bytes`), and EIPs
  (`ElasticIP:IdleAddress`). Route to `aws-data-transfer-profiler` if
  NAT/DataTransfer dominates.
- **S3**: `TimedStorage-*` is storage class x duration; `*-Requests-Tier*`
  is API calls; `DataTransfer-Out-Bytes` is egress.
- **RDS**: `InstanceUsage:db.*` is instance-hours; `Storage:*` and
  `StorageIOUsage` are disk/IO; `BackupUsage` is snapshot storage.
- **Lambda**: look at `Lambda-GB-Second` (compute) vs `Request`
  (invocations) vs `Lambda-Storage-Duration` (function storage).
- **CloudWatch**: `DataProcessing-Bytes` (log ingest — the real killer),
  `TimedStorage-ByteHrs` (log retention).
- **DynamoDB**: `WriteCapacityUnit-Hrs` / `ReadCapacityUnit-Hrs` on
  provisioned tables; `PayPerRequest-*` on on-demand; `TimedStorage*`.

## Output contract

```json
{
  "service": "Amazon Elastic Compute Cloud - Compute",
  "period": { "start": "...", "end": "...", "granularity": "DAILY" },
  "total": 4500.00,
  "by_usage_type": [ { "usage_type": "BoxUsage:m5.xlarge", "amount": 1200.00, "pct": 26.7 } ],
  "by_region": [ { "region": "us-east-1", "amount": 2800.00 } ],
  "by_operation": [ { "operation": "RunInstances", "amount": 3900.00 } ],
  "by_az": [ { "az": "us-east-1a", "amount": 1500.00 } ],
  "by_account": [ { "account_id": "...", "amount": 2000.00 } ],
  "resource_level": {
    "note": "Last 14 days only, hourly granularity.",
    "top_resources": [ { "resource_id": "i-0abc123", "amount": 245.67 } ]
  },
  "meta": { "ce_api_calls": 5, "estimated_cost_usd": 0.05 }
}
```

## Interpreting the results

1. **80/20 rule almost always holds**: the top 3 usage types will account
   for 70-80% of the service's cost. Focus there.
2. **Look for things that shouldn't exist**: if you see `BoxUsage:t2.*`
   in a production account that should be on t3+, that's rightsizing
   signal (route to `aws-cost-optimizer`).
3. **Regional spread = either DR, or accidental sprawl.** Ask the user
   if they expect resources in that region. If not, flag for cleanup.
4. **Cross-AZ charges** (look for `*-Regional-Bytes` or AZ-specific
   BoxUsage clustering) — route to `aws-data-transfer-profiler`.
