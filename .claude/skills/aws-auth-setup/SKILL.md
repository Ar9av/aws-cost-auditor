---
name: aws-auth-setup
description: Set up and verify read-only AWS credentials for the cost auditor. Use this skill whenever the user is starting a fresh audit, when `aws sts get-caller-identity` fails, when the user wants to switch profiles, or when they need the minimum IAM policy JSON to hand to their admin. Covers static IAM access keys (profile or env vars) and AWS SSO / IAM Identity Center.
license: MIT
metadata:
  author: Ar9av
  version: "1.1.0"
---

# aws-auth-setup

The first skill any cost-audit session should touch. Its job is to make sure
the CLI can talk to the right AWS account with **exactly** the permissions
needed to read cost data — no more, no less.

## When to invoke this skill

- User is starting a new audit and hasn't mentioned credentials yet.
- Any script in the pack fails with `Unable to locate credentials`,
  `ExpiredToken`, `AccessDenied`, or `InvalidClientTokenId`.
- User asks "what permissions does this need?" or "how do I give you access?"
- User wants to switch between AWS accounts / profiles / SSO sessions.

## The three credential paths

### 1. Named AWS profile (recommended)

Ask the user if they already have an audit-scoped IAM user or role. If yes,
collect the profile name. If no, walk them through:

```bash
aws configure --profile cost-audit
# prompts for Access Key ID, Secret Access Key, default region, output format
```

Then verify:

```bash
bash .claude/skills/aws-auth-setup/scripts/verify-creds.sh --profile cost-audit
```

### 2. Environment variables (ephemeral)

For a one-shot session. Tell the user to export and confirm the shell exports
are in *your* shell (not theirs) before running anything:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...    # only if using STS temporary creds
export AWS_REGION=us-east-1     # Cost Explorer only works from us-east-1
```

Then `bash .claude/skills/aws-auth-setup/scripts/verify-creds.sh` with no
profile flag.

### 3. AWS SSO / IAM Identity Center

If the user's org uses SSO:

```bash
aws configure sso --profile cost-audit-sso
# interactive flow: SSO start URL, region, account, role
aws sso login --profile cost-audit-sso
```

After login, treat it like a named profile:

```bash
bash .claude/skills/aws-auth-setup/scripts/verify-creds.sh --profile cost-audit-sso
```

If the token has expired (`The SSO session associated with this profile has
expired`), prompt the user to re-run `aws sso login --profile <name>`.

## Cost Explorer region gotcha

All `aws ce ...` calls must be issued from `us-east-1` even if your resources
live elsewhere. The scripts set `AWS_REGION=us-east-1` explicitly for CE
calls — don't fight this.

## Minimum IAM policy

The policy lives at `references/iam-policy.json`. Hand this to the user (or
their admin) verbatim. It allows:

- Cost Explorer read (`ce:Get*`, `ce:List*`, `ce:Describe*`)
- Cost Optimization Hub read (`cost-optimization-hub:Get*`,
  `cost-optimization-hub:List*`)
- Compute Optimizer read (`compute-optimizer:Get*`,
  `compute-optimizer:Describe*`)
- Trusted Advisor via Support API (`support:Describe*`) — **only works on
  Business Support+ plans**; skill gracefully degrades if denied
- Resource listing (`ec2:Describe*`, `elbv2:Describe*`, `rds:Describe*`,
  `s3:ListAllMyBuckets`, `s3:GetBucket*`, `lambda:ListFunctions`,
  `logs:DescribeLogGroups`, `ecr:Describe*`, `ecr:ListImages`)
- CloudWatch metric read (`cloudwatch:GetMetricData`,
  `cloudwatch:GetMetricStatistics`)
- Tag/resource inventory (`tag:GetResources`, `tag:GetTagKeys`)
- Organization read (`organizations:DescribeOrganization`,
  `organizations:ListAccounts`) — optional, for multi-account audits
- Savings Plans read (`savingsplans:Describe*`)

See `references/iam-policy.json` for the full, copy-pasteable policy
document and `references/minimal-iam-policy.md` for a breakdown of why each
permission is needed.

## What to do once creds are verified

Tell the user which account + region you're operating against, then suggest
the natural next skill:

- "What's the spend?" → `aws-cost-snapshot`
- "Where's the waste?" → `aws-waste-hunter`
- "Run the whole thing." → `aws-cost-audit` (orchestrator)

## Output contract

The verify script prints a single JSON object on success:

```json
{
  "account_id": "123456789012",
  "account_alias": "acme-prod",
  "user_arn": "arn:aws:iam::123456789012:user/cost-auditor",
  "region": "us-east-1",
  "profile": "cost-audit",
  "permission_probe": {
    "ce": "ok",
    "compute-optimizer": "ok",
    "cost-optimization-hub": "ok",
    "trusted-advisor": "denied-business-support-required",
    "ec2": "ok",
    "organizations": "denied-not-management-account"
  }
}
```

The `permission_probe` block tells the agent which skills will work. Any
`denied-*` entries should be surfaced to the user with the remediation hint.
