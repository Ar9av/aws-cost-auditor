# AWS data-transfer reference (us-east-1 prices, April 2026)

## Rate card — what each transfer type costs

| Path | Price |
|---|---|
| Within same AZ, private IP | **$0.00/GB** |
| Within same AZ, public/Elastic IP | $0.01/GB each way |
| Cross-AZ, same region | **$0.01/GB each way** ($0.02/GB round-trip) |
| Cross-region (egress from region A) | $0.02/GB |
| Internet egress, 0-1 GB | $0.00/GB (free tier) |
| Internet egress, 1 GB–10 TB | $0.09/GB |
| Internet egress, 10-50 TB | $0.085/GB |
| Internet egress, 50-150 TB | $0.07/GB |
| Internet egress, >150 TB | $0.05/GB |
| NAT Gateway hours | $0.045/hour (~$32.85/month) |
| NAT Gateway processing | **$0.045/GB** on top of transfer |
| VPC Endpoint (interface) hourly | $0.01/hour per AZ |
| VPC Endpoint (interface) processing | $0.01/GB |
| VPC Gateway Endpoint (S3, DynamoDB) | **$0.00** |
| CloudFront egress | $0.085/GB (first 10 TB, varies by region) |
| Public IPv4 (idle or attached) | $0.005/hour ($3.60/month) |

## Usage-type glossary

### NAT

- `NatGateway-Hours` — the $0.045/h fixed charge.
- `NatGateway-Bytes` — the per-GB processing charge. Billed on total
  bytes flowing through, regardless of direction.

### Regional (within a region, cross-AZ)

- `DataTransfer-Regional-Bytes` — EC2 / ELB / VPC traffic that crosses
  AZs inside the same region.

### Inter-region

- `<source-region>-<destination-region>-AWS-Out-Bytes` — egress from
  source to destination.
- `<source-region>-<destination-region>-AWS-In-Bytes` — for services
  that charge the receiving side (rare; most in-traffic is free).

### Internet

- `DataTransfer-Out-Bytes` — egress to internet from an AWS service
  (EC2, S3, RDS, etc.).
- `CloudFront-Out-Bytes` — CloudFront egress to viewers.

### VPC endpoints

- `VpcEndpoint-Hours` — interface endpoint hourly per AZ.
- `VpcEndpoint-Bytes` — data through interface endpoint.

### Public IPv4

- `PublicIPv4:IdleAddress` — EIP not attached.
- `PublicIPv4:InUseAddress` — attached public IPv4 (since Feb 2024).

## Architectural fixes by diagnosis

### "NAT bytes dominate"

1. **Gateway VPC Endpoint for S3**. Free. Add one per VPC, edit route
   tables to route S3 prefix list through it:

   ```bash
   # Read-only audit version — don't run in this skill pack.
   aws ec2 describe-vpc-endpoints --filters Name=service-name,Values=com.amazonaws.<region>.s3
   ```

2. **Gateway VPC Endpoint for DynamoDB**. Same story.

3. **Interface VPC Endpoints for other AWS services**. Per-AZ hourly
   charge ($0.01/h) plus data ($0.01/GB), but replaces NAT for API
   calls to that service. Worth it when NAT processing for that
   service > ~$15/mo.

4. **PrivateLink** for third-party SaaS vendors who offer it.

### "Cross-AZ bytes are large"

Common culprits, in order of frequency:

1. **ALB with cross-zone load balancing enabled** + targets heavily
   skewed to one AZ. Traffic pattern: client → LB (AZ1) → target
   (AZ2) = cross-AZ charge.
2. **EKS** pods in different AZs talking freely; use `topologyKey:
   topology.kubernetes.io/zone` for pod affinity on chatty workloads.
3. **Kafka / Kinesis consumers** pulling from brokers in other AZs.
4. **RDS read replicas** in different AZs from the workload that reads
   them.
5. **Elasticsearch / OpenSearch** shard replication across AZs. This
   is by design for HA; don't break it without understanding.

### "Internet egress is huge"

1. Put **CloudFront** in front of any S3 bucket or ALB serving public
   content. Origin→CF egress is free.
2. Enable **compression** (gzip/br) at the origin.
3. Check for **unintended public exposure** — a bucket with wide read
   permissions that bots are crawling.
4. Check for **accidentally-public RDS** — connections from outside the
   VPC count as egress.

### "Inter-region is non-trivial"

1. Audit cross-region replication for S3 / DynamoDB / RDS. Is the DR
   target being used?
2. Check for **clients in region A calling APIs in region B** — usually
   fixable with a regional endpoint or a replica.

## Further reading

- [Overview of Data Transfer Costs for Common Architectures (AWS)](
  https://aws.amazon.com/blogs/architecture/overview-of-data-transfer-costs-for-common-architectures/)
- [Analyze Data Transfer and adopt cost optimized designs (AWS)](
  https://aws.amazon.com/blogs/industries/analyze-data-transfer-and-adopt-cost-optimized-designs-to-realize-cost-savings/)
