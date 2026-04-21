---
name: aws-data-transfer-profiler
description: Decompose the notoriously opaque AWS data-transfer bill — NAT Gateway processing bytes, cross-AZ traffic, inter-region transfer, internet egress, and CloudFront. Identifies the specific usage types driving spend and recommends architectural fixes (Gateway VPC Endpoints, traffic locality, PrivateLink). Use this skill when the EC2-Other line item is large, "Data Transfer" appears in the top services, or the user asks "why is my networking bill so high".
---

# aws-data-transfer-profiler

Data transfer is the most expensive-per-gigabyte part of AWS and the
hardest to attribute to a specific workload. This skill pulls every
data-transfer-adjacent usage type in the bill, categorizes it by cost
mechanism, and points at architectural remediations.

## When to invoke

- `EC2 - Other` is in the top 5 services.
- `Data Transfer` is a top-level line in the bill.
- User asks about NAT Gateway cost, egress cost, cross-AZ cost,
  inter-region cost, CloudFront cost.
- User is planning a VPC redesign and wants to know where bytes are
  going now.

## What it decomposes

AWS surfaces ~15 distinct data-transfer usage types. The profiler groups
them into buckets by remediation strategy:

| Bucket | Usage types | Typical fix |
|---|---|---|
| **NAT processing** | `NatGateway-Bytes`, `NatGateway-Hours` | Gateway VPC Endpoints for S3/DDB, Interface Endpoints for other services, private connectivity (PrivateLink). |
| **Cross-AZ** | `*-Regional-Bytes`, `DataTransfer-Regional-Bytes` | Pin stateful services to one AZ; use zonal endpoints; cluster-aware placement. |
| **Inter-region** | `<r1>-<r2>-AWS-In-Bytes`, `*-Out-Bytes` | Question whether cross-region replication / reads are necessary. |
| **Internet egress** | `DataTransfer-Out-Bytes` (service-level), `CloudFront-Out-Bytes` | CloudFront / AWS Global Accelerator, origin shield, compression. |
| **VPC endpoints (cost themselves)** | `VpcEndpoint-Hours`, `VpcEndpoint-Bytes` | Consolidate endpoints; sanity-check usage vs NAT costs. |
| **Public IP (IPv4)** | `PublicIPv4:IdleAddress`, `PublicIPv4:InUseAddress` | Move to IPv6 where possible (as of Feb 2024, IPv4 charges apply to ALL public IPv4). |

## Cost

~5-6 CE API calls = **$0.05-0.06**.

## How to run

```bash
bash .claude/skills/aws-data-transfer-profiler/scripts/profile-transfer.sh \
  --profile cost-audit --days 30

# With per-region NAT deep-dive (+1 CE call)
bash .claude/skills/aws-data-transfer-profiler/scripts/profile-transfer.sh \
  --profile cost-audit --days 30 --nat-deep
```

## Output

```json
{
  "period": { "start": "...", "end": "...", "days": 30 },
  "total_data_transfer_cost_usd": 1420.50,
  "buckets": {
    "nat_processing":  { "amount": 640.00, "usage_types": [...] },
    "cross_az":        { "amount": 210.00, "usage_types": [...] },
    "inter_region":    { "amount":  95.00, "usage_types": [...] },
    "internet_egress": { "amount": 420.00, "usage_types": [...] },
    "vpc_endpoints":   { "amount":  40.00, "usage_types": [...] },
    "public_ipv4":     { "amount":  15.50, "usage_types": [...] }
  },
  "top_usage_types": [ { "usage_type": "NatGateway-Bytes", "amount": 580.00, "region": "us-east-1" } ],
  "by_region": [ ... ],
  "recommendations": [
    { "action": "Create Gateway VPC Endpoint for S3 in us-east-1",
      "estimated_monthly_saving_pct": "40-80% of NatGateway-Bytes in that region",
      "rationale": "Gateway endpoints are free; traffic to S3 via NAT is both transfer and processing." }
  ]
}
```

## Interpreting results

### NAT processing is >30% of data-transfer cost

Almost always means S3 and/or DynamoDB traffic is being routed through
NAT. Create **Gateway VPC Endpoints** (free) for those services. See
`references/data-transfer-reference.md` for the route-table change.

### Cross-AZ is large and growing

Check:
1. Stateful services (Kafka, Elasticsearch, RDS read replicas) placed
   across AZs without zonal affinity.
2. Client→LB→target crossing AZs — ALBs with cross-zone LB enabled.
3. EKS pods talking across nodes in different AZs.

### Internet egress dominated by one service (e.g., S3)

- Enable **S3 Transfer Acceleration** only if you need it (it costs more,
  doesn't reduce egress).
- Put a **CloudFront distribution** in front — first hop to CF is free
  egress from origin.
- Check for **unintended public reads** (misconfigured buckets).

### Public IPv4 cost appearing

Since Feb 2024, every public IPv4 is $0.005/hour whether idle or
attached. Route to `aws-waste-hunter` for the idle ones; for attached
but low-traffic ones, consider IPv6 or PrivateLink.

## Reference

`references/data-transfer-reference.md` has the full usage-type glossary
and links to AWS's own data-transfer architecture patterns doc.
