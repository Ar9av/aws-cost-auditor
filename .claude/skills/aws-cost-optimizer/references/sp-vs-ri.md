# Savings Plans vs Reserved Instances — quick reference

When the user asks "should we buy SPs or RIs?", here's the short version.

## Default: Compute Savings Plans

For almost every common case — mixed EC2, Fargate, and Lambda usage across
instance families, regions, and tenancy — **Compute Savings Plans** are
the right answer. They apply automatically across:

- Any EC2 instance family, size, OS, tenancy, and region.
- AWS Fargate (ECS/EKS).
- AWS Lambda (excluding Provisioned Concurrency in some cases).

Discount: up to **66% vs on-demand** at 3-year all-upfront.

## EC2 Instance Savings Plans

Slightly deeper discount (up to **72%**), but locked to one instance family
in one region (e.g., `m5` in `us-east-1`). Same flexibility across size, OS,
and tenancy within that family.

Choose this over Compute SP only if:

- You have a known, large, stable footprint on a specific family (usually
  m5/m6/m7 or c5/c6/c7).
- You don't care about covering Fargate or Lambda.

## Standard Reserved Instances

Very specific: family + size + OS + tenancy + region. Highest discount
(~75% at 3-year all-upfront) but near-zero flexibility. RIs can be
**sold on the RI marketplace** if you can't use them — SPs can't.

Still valuable for:

- RDS (SPs don't cover RDS — RIs are the only commitment discount).
- ElastiCache (same — RIs only).
- OpenSearch / Redshift / DynamoDB reserved capacity.

## Convertible RIs

Same as Standard RIs but can be exchanged for different instance types.
Smaller discount than Standard. Mostly superseded by Compute SPs for EC2
use cases.

## Rule of thumb

1. **EC2 + Fargate + Lambda**: Compute Savings Plans, 1-year, no-upfront.
2. **RDS / ElastiCache / OpenSearch / Redshift**: use the service's own
   Reserved tier. There is no SP equivalent.
3. Start at **1-year, no-upfront** commitments. The marginal discount for
   3-year all-upfront is ~10-15% and you're locking in 3 years of cloud
   strategy.
4. Target **~70-80% of baseline usage** under commitment. Above that you
   start buying insurance against cost spikes that mostly don't happen.

## How to read current commitments

```bash
# Existing Savings Plans
aws savingsplans describe-savings-plans \
  --states Active Queued

# Existing EC2/RDS RIs
aws ec2 describe-reserved-instances --filters Name=state,Values=active
aws rds describe-reserved-db-instances
aws elasticache describe-reserved-cache-nodes

# Utilization (runs as part of aws-cost-optimizer)
bash .claude/skills/aws-cost-optimizer/scripts/sp-ri-utilization.sh --profile cost-audit --human
```

If utilization is <80%, you bought too much. Wait for commitments to
expire rather than buying more.
