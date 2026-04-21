# aws-cost-auditor

A Claude Code skill pack that turns any agent with AWS read-only credentials
into a FinOps analyst. Top-down cost snapshot → per-service drill-down →
orphan/idle resource scan → AWS's own rightsizing recommendations → hidden
data-transfer decomposition → tagging audit → anomaly review, all sequenced
by a single orchestrator.

Every script is plain `bash + aws-cli + jq`. Every finding cites the exact
CLI call that produced it. Nothing in the pack mutates AWS state.

---

## Quickstart (30 seconds)

```bash
# 1. Clone
git clone https://github.com/Ar9av/aws-cost-auditor.git
cd aws-cost-auditor

# 2. Open in Claude Code
claude .

# 3. Ask
> Audit my AWS costs
```

Claude Code auto-discovers the 9 skills under `.claude/skills/` and walks
you through creds → snapshot → findings → report.

---

## What's in the pack

| Skill | What it does | CE API cost |
|---|---|---:|
| `aws-auth-setup` | Credential flow (profile / env vars / SSO) + minimum IAM policy + permission probe. | free |
| `aws-cost-snapshot` | MTD total, previous-month compare, top services, MoM delta, forecast, linked-account breakdown. | ~$0.05-0.08 |
| `aws-cost-deep-dive` | Per-service drill: usage type × region × AZ × operation × (optional) resource-level IDs. | ~$0.03-0.15 |
| `aws-waste-hunter` | Scans every region for orphaned EBS, idle NATs, zombie ELBs, stopped-EC2, old snapshots, CW logs with no retention, unused RDS, empty ECR, idle target groups, unused EIPs. Attaches list-price cost to each finding. | free |
| `aws-cost-optimizer` | Aggregates Cost Optimization Hub + Compute Optimizer (EC2/EBS/Lambda/RDS/ECS/ASG) + Trusted Advisor + current Savings Plan / Reserved Instance utilization. | ~$0.02 |
| `aws-cost-anomalies` | Surfaces Cost Anomaly Detection monitors, findings, and subscription gaps. | ~$0.03 |
| `aws-data-transfer-profiler` | Decomposes the notoriously-opaque data-transfer bill (NAT processing, cross-AZ, inter-region, internet egress, IPv4, VPC endpoints) into buckets with architectural remediations. | ~$0.01 |
| `aws-tagging-audit` | Measures cost-allocation-tag coverage, flags inactive required keys, lists top untagged resources. | ~$0.03-0.05 |
| `aws-cost-audit` | Orchestrator — sequences all of the above with confirmation gates between stages. | ~$0.10-0.25 |

A full audit end-to-end costs about **$0.15-0.30 in Cost Explorer API
charges**. The cost is gated by interactive confirmation at each CE-heavy
stage; nothing runs silently.

---

## Installation

### Option A — clone as a standalone project

Use this when you want to run the auditor as its own project (you're
primarily using Claude Code here).

```bash
git clone https://github.com/Ar9av/aws-cost-auditor.git
cd aws-cost-auditor
claude .
```

The pre-allowlisted permissions in `.claude/settings.json` mean most
read-only AWS commands won't prompt. Writes are explicitly denied.

### Option B — install skills into your existing project

Use this when you want the auditor available inside a different repo
you're already working in.

```bash
# From inside your existing repo:
mkdir -p .claude/skills
git clone --depth=1 https://github.com/Ar9av/aws-cost-auditor.git /tmp/auditor
cp -R /tmp/auditor/.claude/skills/* .claude/skills/
chmod +x .claude/skills/*/scripts/*.sh
```

Then merge the relevant permission entries from
`/tmp/auditor/.claude/settings.json` into your `.claude/settings.json`.

### Option C — install skills user-wide

Use this when you want these skills available in **every** Claude Code
project on your machine without per-project setup.

```bash
mkdir -p ~/.claude/skills
git clone --depth=1 https://github.com/Ar9av/aws-cost-auditor.git /tmp/auditor
cp -R /tmp/auditor/.claude/skills/* ~/.claude/skills/
chmod +x ~/.claude/skills/*/scripts/*.sh
```

User-wide skills are always discoverable, regardless of which repo you
open Claude Code in.

### Option D — standalone scripts (no agent)

The scripts don't need an agent. Run them directly on a cron, in CI, or
ad-hoc:

```bash
# Daily waste report
bash .claude/skills/aws-waste-hunter/scripts/run-all.sh \
  --profile cost-audit --human > reports/$(date -u +%F)-waste.md
```

See the "Standalone usage" section below.

---

## Prerequisites

- **AWS CLI v2** — `aws --version` should show 2.x.
- **jq** — `brew install jq` / `apt-get install jq`.
- **bash 3.2+** — macOS default bash works; GNU bash is fine too. No bashism beyond what both support.
- **Claude Code** (optional, only for agent-mode) — [install](https://docs.anthropic.com/en/docs/claude-code).

---

## Setting up AWS credentials (read-only)

The skill pack needs read-only access. Create a dedicated IAM user/role
and attach the policy at
[`.claude/skills/aws-auth-setup/references/iam-policy.json`](.claude/skills/aws-auth-setup/references/iam-policy.json).

The policy grants:

- Cost Explorer (`ce:*` read-only)
- Cost Optimization Hub + Compute Optimizer (read-only)
- Trusted Advisor via Support API (read-only — needs Business Support+ to return data, skill degrades gracefully otherwise)
- Resource inventory (`ec2:Describe*`, `elbv2:Describe*`, `rds:Describe*`, `s3:ListAllMyBuckets`, `lambda:ListFunctions`, `logs:DescribeLogGroups`, `ecr:Describe*`, etc.)
- CloudWatch metric read (for idle-detection)
- Resource tagging (`tag:GetResources`) for the tagging audit
- Organizations read (optional, for multi-account breakdowns)
- Savings Plans read

See [`minimal-iam-policy.md`](.claude/skills/aws-auth-setup/references/minimal-iam-policy.md)
for a per-permission rationale you can show your security team.

### Configuration options

**Named profile (recommended):**

```bash
aws configure --profile cost-audit
# Then in Claude Code:
> Audit my AWS costs using profile cost-audit
```

**Environment variables:**

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
```

**AWS SSO / IAM Identity Center:**

```bash
aws configure sso --profile cost-audit-sso
aws sso login --profile cost-audit-sso
```

### Verify creds before running anything else

```bash
bash .claude/skills/aws-auth-setup/scripts/verify-creds.sh --profile cost-audit
```

Prints a single JSON object with your account, ARN, and a permission
probe for each service family.

---

## Usage from Claude Code

The skill descriptions match a broad set of natural-language phrasings.
Any of these auto-route to the right skill:

| Ask Claude Code | Runs |
|---|---|
| "Set up AWS credentials for a cost audit" | `aws-auth-setup` |
| "What are we spending on AWS?" / "Show me a cost overview" | `aws-cost-snapshot` |
| "Why is EC2 so expensive?" / "Drill into S3 costs" | `aws-cost-deep-dive` |
| "Find wasted resources" / "What can I delete?" | `aws-waste-hunter` |
| "What should I rightsize?" / "Savings Plan recommendations" | `aws-cost-optimizer` |
| "Any cost anomalies?" / "Why did the bill spike?" | `aws-cost-anomalies` |
| "Why is data transfer so high?" / "NAT Gateway costs" | `aws-data-transfer-profiler` |
| "Check tag coverage" / "Untagged spend" | `aws-tagging-audit` |
| "Audit my AWS costs" / "Full FinOps review" | `aws-cost-audit` (orchestrator) |

## Standalone usage (no agent)

All scripts are usable from any shell — cron them, pipe them into
dashboards, whatever.

```bash
# Cheap monthly overview
bash .claude/skills/aws-cost-snapshot/scripts/snapshot.sh \
  --profile cost-audit --forecast --human

# Per-service drill-down
bash .claude/skills/aws-cost-deep-dive/scripts/drill-service.sh \
  --profile cost-audit --service "Amazon Elastic Compute Cloud - Compute" --human

# Full waste scan across all regions
bash .claude/skills/aws-waste-hunter/scripts/run-all.sh \
  --profile cost-audit --human

# AWS's own recommendations
bash .claude/skills/aws-cost-optimizer/scripts/run-all.sh \
  --profile cost-audit --human

# Data-transfer breakdown
bash .claude/skills/aws-data-transfer-profiler/scripts/profile-transfer.sh \
  --profile cost-audit --days 30 --human

# Tagging audit
bash .claude/skills/aws-tagging-audit/scripts/tagging-audit.sh \
  --profile cost-audit --required "Project,Environment,Owner" --human

# Anomalies
bash .claude/skills/aws-cost-anomalies/scripts/anomalies.sh \
  --profile cost-audit --human

# The works
bash .claude/skills/aws-cost-audit/scripts/run-audit.sh \
  --profile cost-audit --all --yes
```

Every script accepts `--profile`, `--output-dir`, and `--human` (for
markdown instead of raw JSON). Output lands in `reports/` (gitignored).

### Cron example

```cron
# Daily 7am UTC: waste scan + snapshot → Slack via webhook
0 7 * * * cd ~/aws-cost-auditor && \
  bash .claude/skills/aws-cost-audit/scripts/run-audit.sh \
    --profile cost-audit --all --yes && \
  curl -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"$(cat reports/$(date -u +%F)-audit.md | head -30)\"}" \
    $SLACK_WEBHOOK_URL
```

---

## Portability to other agent runtimes

The pack is primarily targeted at Claude Code, but the scripts are plain
bash. `AGENTS.md` at the root is picked up by Codex, Factory Droid,
OpenCode, Gemini CLI, Copilot CLI, Kiro, Hermes, and OpenClaw (see
[ai-coding-agents-reference](https://github.com/Ar9av/aws-cost-auditor/blob/main/AGENTS.md)).

For any of those, the pattern is:

1. Agent reads `AGENTS.md` for project rules.
2. Agent reads `.claude/skills/<name>/SKILL.md` for per-skill instructions.
3. Agent runs `bash .claude/skills/<skill>/scripts/<name>.sh --profile <p>`.

If you use one of these agents and want a native port (e.g., as
`.factory/skills/`), open an issue.

---

## Repo layout

```
aws-cost-auditor/
├── README.md, CLAUDE.md, AGENTS.md, .gitignore
├── .claude/
│   ├── settings.json              # read-only aws.* allowlist; writes denied
│   └── skills/
│       ├── aws-auth-setup/
│       │   ├── SKILL.md
│       │   ├── scripts/           # verify-creds.sh, list-profiles.sh
│       │   └── references/        # iam-policy.json, minimal-iam-policy.md
│       ├── aws-cost-snapshot/
│       │   ├── SKILL.md
│       │   └── scripts/           # snapshot.sh, render-summary.sh
│       ├── aws-cost-deep-dive/
│       │   ├── SKILL.md
│       │   ├── scripts/           # drill-service.sh
│       │   └── references/        # service-playbooks.md
│       ├── aws-waste-hunter/
│       │   ├── SKILL.md
│       │   ├── scripts/           # 10 orphan-scanners + run-all.sh + _lib.sh
│       │   └── references/        # waste-signals.md
│       ├── aws-cost-optimizer/
│       │   ├── SKILL.md
│       │   ├── scripts/           # cost-optimization-hub, compute-optimizer, trusted-advisor, sp-ri-utilization, run-all
│       │   └── references/        # sp-vs-ri.md
│       ├── aws-cost-anomalies/
│       │   ├── SKILL.md
│       │   └── scripts/           # anomalies.sh
│       ├── aws-data-transfer-profiler/
│       │   ├── SKILL.md
│       │   ├── scripts/           # profile-transfer.sh
│       │   └── references/        # data-transfer-reference.md
│       ├── aws-tagging-audit/
│       │   ├── SKILL.md
│       │   └── scripts/           # tagging-audit.sh
│       └── aws-cost-audit/
│           ├── SKILL.md
│           └── scripts/           # run-audit.sh, render-audit.sh
└── reports/                       # audit output lands here (gitignored)
```

45 files total — 9 `SKILL.md` files, 27 bash scripts, 6 reference docs,
3 root docs.

---

## Safety model

- **Read-only enforced in three places:**
  1. IAM policy (no `*:Create*`, `*:Put*`, `*:Modify*`, `*:Delete*`, etc.).
  2. `.claude/settings.json` explicit `deny` list for any mutating `aws` verb.
  3. `CLAUDE.md` hard rule telling the agent to never propose write operations.

- **No data leaves AWS.** Scripts only write to the local `reports/`
  directory (gitignored). No telemetry, no phone-home.

- **Cost Explorer charges are gated.** Each CE-heavy stage prints the
  estimated spend and asks before proceeding. `--yes` / `--all` override
  for scripted use.

- **Graceful degradation.** Skills detect when Cost Optimization Hub
  isn't enrolled, Trusted Advisor isn't available, Compute Optimizer
  isn't enabled, Organizations access is missing — they report the gap
  instead of failing.

---

## Why not use the AWS MCP servers?

AWS ships official MCP servers for Billing, Cost Explorer, Pricing, etc.
They're great, and I used them as reference while designing this pack.
This pack exists because:

- **No MCP runtime needed.** The scripts work in any shell — cron, CI,
  local. MCP servers need a running host.
- **Transparent CLI trail.** Every finding cites the exact `aws …`
  command. You can re-run it yourself and get the same number.
- **Least-privilege IAM.** You ship one policy JSON to your admin
  and you're done. MCP servers sometimes want broader surface.
- **Runs on cron without an agent.** Want a daily waste report? One
  cron line; no agent needed.

If you want the MCP-based equivalent, see the
[ordinary-claude-skills aws-skills pack](https://github.com/Microck/ordinary-claude-skills/tree/main/skills_all/aws-skills)
which was a design reference here.

---

## Roadmap

- [ ] CUR 2.0 parquet-on-S3 analysis for line-item-grade resolution.
- [ ] HTML report with inline charts (currently markdown + JSON).
- [ ] Multi-account fan-out (assume-role across an Organization).
- [ ] "What changed since last run?" — diff two audit reports.
- [ ] `aws-cdk-validator` skill: scan CDK/Terraform plans for
      cost-inefficient patterns before merge.
- [ ] Native ports to Codex / Factory Droid / OpenCode skill formats.

Open an issue / PR if you want one of these sooner.

---

## Contributing

Skills are intentionally small and focused — one concern per skill. If
you're adding one:

1. Create `.claude/skills/<name>/` with `SKILL.md` (YAML frontmatter:
   `name:` and `description:` are mandatory).
2. Scripts go under `scripts/`; references under `references/`.
3. Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, a usage
   block, support for `--profile` and `--output-dir`, and never mutate
   AWS state.
4. Description field should name what the skill covers and when to use
   it — that's what drives Claude Code's auto-invocation.

See `CLAUDE.md` for the full project rules.

---

## License

MIT. See `LICENSE`.

---

## Acknowledgements

- [Microck/ordinary-claude-skills](https://github.com/Microck/ordinary-claude-skills/tree/main/skills_all/aws-skills) — starting-point reference for the AWS skill pattern.
- [kosty-cloud/kosty](https://github.com/kosty-cloud/kosty) — reference for what a thorough AWS audit tool's check coverage looks like.
- The [AWS Cost Optimization Hub](https://docs.aws.amazon.com/cost-management/latest/userguide/cost-optimization-hub.html)
  and [Compute Optimizer](https://docs.aws.amazon.com/compute-optimizer/)
  teams for building the APIs this pack leans on.
