# Waste signal reference

How each check decides something is "waste" — so you can explain findings
to the user confidently, or tune thresholds if they complain about
false positives.

## `ebs-unattached`

- **Signal**: `Volume.State == "available"` (not attached to any instance).
- **Why it's waste**: a detached volume is billed at the same per-GB-month
  rate as an attached one.
- **False-positive risk**: low. Occasionally a detached volume is staged
  for disaster recovery; check for a `cost-audit:retain` tag before
  flagging.
- **Remediation**: `aws ec2 create-snapshot` (optional safety net) →
  `aws ec2 delete-volume`.

## `eips-unused`

- **Signal**: Elastic IP with no `AssociationId`.
- **Why it's waste**: AWS bills $0.005/hour per unassociated EIP to
  discourage hoarding ($3.60/mo).
- **False-positive risk**: low. EIPs reserved for failover are rare.
- **Remediation**: `aws ec2 release-address --allocation-id <id>`.

## `nat-idle`

- **Signal**: NAT Gateway with `<1MB` total `BytesOutToSource` in last
  14 days.
- **Why it's waste**: ~$32.85/month hourly alone, regardless of traffic.
- **False-positive risk**: medium. A NAT for a DR-only VPC is low-traffic
  by design. Check if the VPC has any recent activity (VPC Flow Logs).
- **Remediation**: `aws ec2 delete-nat-gateway`. Remember to release
  the EIP afterwards.

## `elbs-idle`

- **Signal**: Load balancer with 0 healthy targets across all TGs.
- **Why it's waste**: ~$16.43/mo just for existing.
- **False-positive risk**: medium. An ALB just created by a deploy may
  briefly have 0 healthy targets.
- **Remediation**: `aws elbv2 delete-load-balancer`. Confirm it's not
  the default target of a Route 53 record first.

## `ec2-stopped`

- **Signal**: Instance `state=stopped` for >30 days (from
  `StateTransitionReason`).
- **Why it's waste**: instance-hours are not billed, but attached EBS is.
  Each 100 GB gp2 root volume costs ~$10/mo.
- **False-positive risk**: medium. Teams sometimes keep "dev sandbox"
  instances stopped.
- **Remediation**: confirm with owner → `aws ec2 terminate-instances`
  (EBS volumes with `DeleteOnTermination=true` go away automatically).

## `snapshot-old-orphan`

- **Signal**: Snapshot >180 days AND source volume no longer exists AND
  not referenced by an AMI.
- **Why it's waste**: $0.05/GB-month forever.
- **False-positive risk**: low if we exclude AMI-backing snapshots
  (the script currently doesn't — add an AMI check before auto-delete).
- **Remediation**: `aws ec2 delete-snapshot --snapshot-id <id>`.

## `cw-logs-noretention`

- **Signal**: Log group with `retentionInDays == null`.
- **Why it's waste**: costs grow forever at $0.03/GB-month.
- **False-positive risk**: medium if the log group is required for
  compliance > 1 year.
- **Remediation**: `aws logs put-retention-policy --log-group-name <n>
  --retention-in-days <30|60|90|365>`.

## `rds-idle`

- **Signal**: `DatabaseConnections.Maximum == 0` over 14 days.
- **Why it's waste**: RDS bills full instance-hours regardless of
  connections.
- **False-positive risk**: medium. Some DBs are woken up once a quarter.
- **Remediation**: snapshot + delete, or scale down to a smaller instance
  class / switch to Aurora Serverless.

## `ecr-empty`

- **Signal**: Repository with 0 images for >30 days.
- **Why it's tracked**: ECR storage is free, but empty repos signal dead
  projects — useful context for broader cleanup conversations.
- **False-positive risk**: high as a *waste* signal (no cost); keep as
  informational only.

## `target-groups-empty`

- **Signal**: Target group with 0 registered targets.
- **Why it's tracked**: TGs themselves are free but often paired with
  idle ALBs/NLBs.
- **Remediation**: `aws elbv2 delete-target-group` (and the LB, if also
  idle).

## Checks intentionally not (yet) included

- **Oversized EBS** (rightsizing is `aws-cost-optimizer`).
- **S3 Glacier-eligible objects** (needs S3 Storage Lens / Inventory).
- **Old AMIs without dependent launches** (requires EC2 API walks +
  Launch Template refs; adds time without obvious payoff for MVP).
- **KMS keys with no usage** (requires CloudTrail lookup — separate
  analysis skill).

## Tunable thresholds

If the user complains about false positives, the main dials are:

| Check | Threshold (default) | Where to change |
|---|---|---|
| `nat-idle` | <1MB / 14d | `nat-idle.sh: THRESHOLD_BYTES, days_ago 14` |
| `ec2-stopped` | >30d stopped | `ec2-stopped.sh: STOP_CUTOFF` |
| `snapshots-old` | >180d age | `snapshots-old.sh: AGE_CUTOFF` |
| `rds-idle` | 0 conn / 14d | `rds-idle.sh: start/end` |
