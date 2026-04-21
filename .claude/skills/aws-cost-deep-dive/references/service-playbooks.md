# Per-service drill-down playbooks

For the services that appear most often in the top 10 of the AWS bill,
here's what to look for *after* running `drill-service.sh`, and which
skill to route to next.

Treat this as a cheat-sheet, not a substitute for reading the actual
numbers. Every account is different.

---

## Amazon Elastic Compute Cloud - Compute  (the "EC2 instance-hours" line)

**What's in it**: strictly compute time — the per-instance-hour charge.
Does not include EBS, data transfer, or snapshots; those live in
`EC2 - Other`.

**Usage types to know**:

| Usage type | What it means |
|---|---|
| `BoxUsage:<type>` | On-demand instance-hours for that instance type. |
| `SpotUsage:<type>` | Spot instance-hours. |
| `HeavyUsage:<type>` / `MediumUsage:<type>` | RI coverage (a cost, offset by SP/RI discount on the same bill). |
| `DedicatedUsage:<type>` | Dedicated hosts / instances. |

**Common wins**:

- Long tail of t2 / t3 / m4 instance-hours → rightsize or move to Graviton
  (`m7g`, `c7g`). Route to `aws-cost-optimizer`.
- Large `BoxUsage:*` share with no `SpotUsage:*` → candidate for Spot on
  batch / non-prod.
- Significant `HeavyUsage:*` without matching `SpotUsage:*` means RIs are
  being burned on rigid workloads; consider Savings Plans for flexibility.

**Next skill**: `aws-cost-optimizer` for rightsizing recs.

---

## EC2 - Other  (the "everything else EC2" line — frequently top 3)

**What's in it**: EBS volumes/snapshots, NAT Gateway hours+bytes,
inter-region data transfer, inter-AZ data transfer, EIPs.

**Usage types to know**:

| Usage type | What it means |
|---|---|
| `EBS:VolumeUsage.<type>` | Per-GB-month for the volume (gp3 / gp2 / io2 / etc). |
| `EBS:SnapshotUsage` | Snapshot storage (GB-month). |
| `EBS:VolumeP-IOPS.io2` / `VolumeP-Throughput.gp3` | Provisioned IOPS / throughput. |
| `NatGateway-Hours` | Fixed NAT hourly ($0.045/h us-east-1). |
| `NatGateway-Bytes` | NAT data processing ($0.045/GB). |
| `DataTransfer-Regional-Bytes` | Cross-AZ data transfer. |
| `DataTransfer-Out-Bytes` | Egress to internet. |
| `<region1>-<region2>-AWS-Out-Bytes` | Inter-region transfer. |
| `ElasticIP:IdleAddress` | EIP not attached to a running instance. |

**Common wins**:

- `NatGateway-Bytes` > $500/mo → `aws-data-transfer-profiler`, consider
  Gateway VPC Endpoints for S3/DynamoDB.
- Large `EBS:SnapshotUsage` → check for stale snapshots of deleted
  volumes → `aws-waste-hunter`.
- `EBS:VolumeUsage.gp2` dominant → migration to gp3 is ~20% cheaper at
  same performance.

**Next skill**: `aws-data-transfer-profiler` and/or `aws-waste-hunter`.

---

## Amazon Simple Storage Service  (S3)

**Usage types to know**:

| Usage type | What it means |
|---|---|
| `TimedStorage-ByteHrs` | Standard storage (GB-hour → GB-month). |
| `TimedStorage-IA-ByteHrs` | Standard-IA. |
| `TimedStorage-GlacierByteHrs` / `-GIRByteHrs` | Glacier Flexible / Instant Retrieval. |
| `TimedStorage-DeepArchiveByteHrs` | Glacier Deep Archive. |
| `Requests-Tier1` | PUT / COPY / POST / LIST (pricey). |
| `Requests-Tier2` | GET / SELECT. |
| `DataTransfer-Out-Bytes` | Egress to internet. |
| `Inventory-ObjectsListed` | Inventory reports. |

**Common wins**:

- A lot of `TimedStorage-ByteHrs` with little movement to IA/Glacier →
  enable lifecycle rules / Intelligent-Tiering.
- Large `Requests-Tier1` on a bucket used mostly for reads → check
  whether a workload is re-uploading instead of caching.

**Next skill**: `aws-waste-hunter` (for old / orphan buckets),
`aws-cost-optimizer` (lifecycle advisories).

---

## Amazon Relational Database Service (RDS / Aurora)

**Usage types**:

| Usage type | What it means |
|---|---|
| `InstanceUsage:db.<type>` | RDS instance-hours. |
| `Multi-AZUsage:db.<type>` | Multi-AZ (2x price). |
| `Aurora:ServerlessUsage` | Aurora Serverless v2 ACU-hours. |
| `Aurora:StorageUsage` | Aurora storage (pay per GB-month). |
| `RDS:GP2-Storage` / `GP3-Storage` / `PIOPS-Storage` | EBS-equivalent. |
| `RDS:ChargedBackupUsage` | Backup storage beyond free allotment. |
| `BackupUsage` | Manual snapshots. |

**Common wins**:

- Oversized `InstanceUsage:db.r*` → Compute Optimizer now covers RDS
  (Dec 2023+). Route to `aws-cost-optimizer`.
- `Multi-AZUsage` on non-prod → confirm that's intentional.
- Large `BackupUsage` → check retention policy + cross-region copies.

---

## AWS Lambda

**Usage types**:

| Usage type | What it means |
|---|---|
| `Lambda-GB-Second` | Compute (memory × duration). |
| `Request` | Number of invocations. |
| `Lambda-Edge-GB-Second` / `Request-Edge` | Lambda@Edge. |
| `Lambda-Provisioned-Concurrency` | Provisioned concurrency (pay even when idle). |
| `Lambda-Storage-Duration` | Ephemeral /tmp beyond 512 MB. |

**Common wins**:

- `GB-Second` dominates over `Request` → memory is overprovisioned
  **or** duration is too long. Compute Optimizer flags this.
- Provisioned concurrency enabled and `Lambda-Provisioned-Concurrency`
  is large → is the traffic steady enough to justify it?

---

## Amazon CloudWatch

**Usage types**:

| Usage type | What it means |
|---|---|
| `DataProcessing-Bytes` | **Log ingest** — $0.50/GB us-east-1, often the biggest line. |
| `TimedStorage-ByteHrs` | Log retention. |
| `CW:MetricMonitorUsage` | Custom metrics. |
| `CW:AlarmMonitorUsage` | Alarms. |
| `CW:Requests` | PutMetricData, GetMetricStatistics requests. |

**Common wins**:

- Any log group without retention → route to `aws-waste-hunter`.
- High `DataProcessing-Bytes` from one log group → sample / filter logs
  at source.

---

## Amazon DynamoDB

**Usage types**:

| Usage type | What it means |
|---|---|
| `WriteCapacityUnit-Hrs` / `ReadCapacityUnit-Hrs` | Provisioned capacity. |
| `PayPerRequestThroughput` (WriteRequestUnits / ReadRequestUnits) | On-demand. |
| `TimedStorage-ByteHrs` | Storage. |
| `DataExport-Bytes` | Export to S3. |
| `TimedBackupStorage-ByteHrs` | PITR / on-demand backups. |

**Common wins**:

- Provisioned tables with auto-scaling off and headroom > 3x → switch
  to on-demand or tune auto-scaling.
- Predictable traffic on on-demand tables → switch to provisioned with
  reserved capacity.

---

## Key / easy-to-miss services

- **KMS**: `Requests-Encrypted*` — every Encrypt/Decrypt is a chargeable
  API call. S3 SSE-KMS with small objects can be expensive.
- **NAT per-AZ on multi-AZ ASG**: if you see three `NatGateway-Hours`
  line items, you've got one per AZ — by design, but verify needed.
- **Secrets Manager**: $0.40/month per secret — orphaned secrets add up.
- **VPC Endpoints**: `VpcEndpoint-Hours` for interface endpoints.
  Gateway endpoints (S3/DDB) are free.
- **CloudFront**: `DataTransfer-Out-Bytes` is almost always dominant;
  consider origin shield if origin transfer is also large.
- **ElastiCache**: `NodeUsage:<type>`.
- **OpenSearch / Elasticsearch Service**: `ES:InstanceHour.*`,
  `ES:Storage-GB-Hours`.
