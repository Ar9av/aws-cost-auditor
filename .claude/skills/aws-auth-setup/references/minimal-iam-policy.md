# Why each permission is in the policy

Every statement in `iam-policy.json` exists because at least one script in
this pack needs it. If you want to trim further, here is the mapping — you
can drop a statement if you don't plan to use the matching skill.

## `CostExplorerRead` (mandatory)

Used by: `aws-cost-snapshot`, `aws-cost-deep-dive`, `aws-cost-anomalies`,
`aws-data-transfer-profiler`, `aws-tagging-audit`.

This is Cost Explorer. Without it, nothing that talks about historical
spend will work. Note that `ce:GetCostAndUsageWithResources` is the one
call that returns resource-level IDs — but only for the last 14 days and
only if you've enabled hourly granularity in the Cost Management console
(Preferences → Cost Explorer → Enable hourly and resource-level data).

## `CostOptimizationHubRead`

Used by: `aws-cost-optimizer`.

Cost Optimization Hub aggregates recommendations from Compute Optimizer,
Trusted Advisor, Reservations, and Savings Plans into a single priority-sorted
list with savings estimates. It must be enabled once in the Billing console
before any data shows up. Drop this block if you want Compute Optimizer /
Trusted Advisor raw output only.

## `ComputeOptimizerRead`

Used by: `aws-cost-optimizer`, `aws-cost-deep-dive` (for EC2/RDS/Lambda).

Compute Optimizer is the source of rightsizing recommendations for EC2,
EBS, Lambda, Auto Scaling groups, ECS-on-Fargate services, and RDS. It
needs ≥14 days of utilization metrics to generate useful recs — less than
that, expect empty results.

## `TrustedAdvisorRead`

Used by: `aws-cost-optimizer` (Trusted Advisor path).

All accounts see 56 basic Trusted Advisor checks. **The full 482-check set
and the API itself require Business Support+, Enterprise Support, or
Unified Operations.** On Basic/Developer plans, these calls return
`AccessDenied` or `SubscriptionRequiredException` — the skill detects
this and falls back to Compute Optimizer + Cost Optimization Hub only.

Both `support:*` and the newer `trustedadvisor:*` namespaces are listed
because AWS is mid-migration.

## `ResourceInventoryRead`

Used by: `aws-waste-hunter`, `aws-tagging-audit`, `aws-cost-deep-dive`.

Read-only `Describe*`/`List*` calls across the services that produce the
bulk of most AWS bills. The waste hunter needs to see the actual resources
to cross-reference what the bill charges for.

## `MetricsRead`

Used by: `aws-waste-hunter` (to confirm "idle" status — e.g., a load
balancer with zero active connections for 14 days), `aws-cost-optimizer`.

CloudWatch metric reads are free (requests are, at least — the underlying
metric ingestion was already paid for).

## `TaggingAndResourceGroups`

Used by: `aws-tagging-audit`, `aws-waste-hunter`.

The `tag:GetResources` API is the single best way to inventory every
tagged resource across every service in a region without hammering
individual service APIs.

## `OrganizationsReadOptional`

Used by: `aws-cost-snapshot` (to group by linked account), multi-account
audits in general.

Safe to omit if you're auditing a standalone account. The skills detect
the missing permission and skip per-account breakdowns.

## `SavingsPlansRead`

Used by: `aws-cost-optimizer`.

Needed to show current Savings Plan commitments and utilization. Drop if
you don't use SPs.

## `IdentitySelfRead`

Used by: every skill.

`sts:GetCallerIdentity` is the health-check probe. `iam:ListAccountAliases`
gives the friendly name (e.g., `acme-prod`) for nicer reports.

## What's explicitly **not** here

No write permissions of any kind. No `ce:CreateAnomalyMonitor`, no
`iam:PassRole`, no `logs:CreateLogGroup`. If a skill seems to want write
access, that's a bug — file an issue, don't grant it.

## Alternate: use the AWS managed policy

If your org prefers AWS-managed policies over custom ones, a workable
(slightly over-scoped) combination is:

- `arn:aws:iam::aws:policy/job-function/Billing` (or `ViewBillingOnly`)
- `arn:aws:iam::aws:policy/ReadOnlyAccess`
- `arn:aws:iam::aws:policy/ComputeOptimizerReadOnlyAccess`
- `arn:aws:iam::aws:policy/CostOptimizationHubReadOnlyAccess`

This gives more than the custom policy above (full `ReadOnlyAccess` sees a
lot more than cost), but it's operationally simpler for some teams.
