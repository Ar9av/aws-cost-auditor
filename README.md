# aws-cost-auditor

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![bash](https://img.shields.io/badge/shell-bash-blue)](https://www.gnu.org/software/bash/)
[![aws-cli](https://img.shields.io/badge/aws--cli-v2-orange)](https://aws.amazon.com/cli/)
[![jq](https://img.shields.io/badge/jq-1.6%2B-green)](https://jqlang.github.io/jq/)

**One skill pack. Any agent. Full AWS FinOps picture.**

Top-down cost snapshot → per-service drill-down → orphan/idle resource scan → rightsizing recommendations → data-transfer decomposition → tagging audit → anomaly review — all sequenced by a single orchestrator.

Every script is plain `bash + aws-cli + jq`. Every finding cites the exact CLI call that produced it. Nothing mutates AWS state.

---

## What you get

| Skill | What it does | CE API cost |
|---|---|---:|
| `aws-auth-setup` | Credential flow (profile / env vars / SSO) + minimum IAM policy + permission probe | free |
| `aws-cost-snapshot` | MTD total, previous-month compare, top services, MoM delta, forecast, linked-account breakdown | ~$0.05–0.08 |
| `aws-cost-deep-dive` | Per-service drill: usage type × region × AZ × operation × (optional) resource-level IDs | ~$0.03–0.15 |
| `aws-waste-hunter` | Scans every region for orphaned EBS, idle NATs, zombie ELBs, stopped EC2, old snapshots, CW logs with no retention, unused RDS, empty ECR, idle target groups, unused EIPs | free |
| `aws-cost-optimizer` | Cost Optimization Hub + Compute Optimizer (EC2/EBS/Lambda/RDS/ECS/ASG) + Trusted Advisor + SP/RI utilization | ~$0.02 |
| `aws-cost-anomalies` | Anomaly Detection monitors, findings, and subscription gaps | ~$0.03 |
| `aws-data-transfer-profiler` | Decomposes data-transfer bill (NAT processing, cross-AZ, inter-region, internet egress, IPv4, VPC endpoints) | ~$0.01 |
| `aws-tagging-audit` | Cost-allocation-tag coverage, inactive required keys, top untagged resources | ~$0.03–0.05 |
| `aws-cost-audit` | Orchestrator — sequences all of the above with confirmation gates | ~$0.10–0.25 |

A full audit costs about **$0.15–0.30 in Cost Explorer API charges**. Each CE-heavy stage asks for confirmation before running.

---

## Why script-based

- **No runtime needed.** Works in any shell — cron, CI, local. No MCP server, no Node.js, no daemon.
- **Transparent CLI trail.** Every finding cites the exact `aws …` command. Re-run it yourself and get the same number.
- **Least-privilege IAM.** One policy JSON to your admin and you're done.
- **Cron-friendly.** `bash skill.sh --all --yes` and pipe to Slack. No agent required.

---

## Install in 60 seconds

### Prerequisites

- **AWS CLI v2** — `aws --version` should show `2.x`
- **jq** — `brew install jq` / `apt-get install jq`
- **bash 3.2+** — macOS default bash works

### Claude Code

**Option A — standalone project (recommended for first run)**

```bash
git clone https://github.com/Ar9av/aws-cost-auditor.git
cd aws-cost-auditor
claude .
```

The pre-allowlisted permissions in `.claude/settings.json` mean most read-only AWS commands won't prompt for approval.

**Option B — drop into an existing project**

```bash
# From inside your existing repo:
mkdir -p .claude/skills
git clone --depth=1 https://github.com/Ar9av/aws-cost-auditor.git /tmp/auditor
cp -R /tmp/auditor/.claude/skills/* .claude/skills/
chmod +x .claude/skills/*/scripts/*.sh
```

Merge the permission entries from `/tmp/auditor/.claude/settings.json` into your own `.claude/settings.json`.

**Option C — user-wide (available in every project)**

```bash
mkdir -p ~/.claude/skills
git clone --depth=1 https://github.com/Ar9av/aws-cost-auditor.git /tmp/auditor
cp -R /tmp/auditor/.claude/skills/* ~/.claude/skills/
chmod +x ~/.claude/skills/*/scripts/*.sh
```

### Cursor

```bash
git clone https://github.com/Ar9av/aws-cost-auditor.git
```

Open the folder in Cursor. The `.cursor-plugin/plugin.json` is picked up automatically. Reference skill instructions from `.claude/skills/<name>/SKILL.md` in your prompts or Rules.

### Gemini CLI

```bash
git clone https://github.com/Ar9av/aws-cost-auditor.git
cd aws-cost-auditor
gemini  # gemini-extension.json is auto-loaded
```

### GitHub Copilot CLI / Codex / other agents

Any agent that reads `AGENTS.md` (Codex, Factory Droid, OpenCode, Kiro, Hermes, OpenClaw) works out of the box:

```bash
git clone https://github.com/Ar9av/aws-cost-auditor.git
cd aws-cost-auditor
# Point your agent at this directory — it will read AGENTS.md for project rules
# and .claude/skills/<name>/SKILL.md for per-skill instructions
```

The pattern for any agent:
1. Read `AGENTS.md` for project rules
2. Read `.claude/skills/<name>/SKILL.md` for per-skill instructions
3. Run `bash .claude/skills/<name>/scripts/<script>.sh --profile <profile>`

### Standalone (no agent, cron / CI)

The scripts work without any agent:

```bash
# Cost overview
bash .claude/skills/aws-cost-snapshot/scripts/snapshot.sh \
  --profile cost-audit --forecast --human

# Waste scan across all regions
bash .claude/skills/aws-waste-hunter/scripts/run-all.sh \
  --profile cost-audit --human

# Full audit, non-interactive
bash .claude/skills/aws-cost-audit/scripts/run-audit.sh \
  --profile cost-audit --all --yes
```

**Cron example — daily 7am UTC waste report to Slack:**

```cron
0 7 * * * cd ~/aws-cost-auditor && \
  bash .claude/skills/aws-cost-audit/scripts/run-audit.sh \
    --profile cost-audit --all --yes && \
  curl -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"$(cat reports/$(date -u +%F)-audit.md | head -30)\"}" \
    $SLACK_WEBHOOK_URL
```

---

## AWS credentials

The skill pack needs read-only access. Create a dedicated IAM user/role and attach the policy at [`.claude/skills/aws-auth-setup/references/iam-policy.json`](.claude/skills/aws-auth-setup/references/iam-policy.json).

**Named profile (recommended):**

```bash
aws configure --profile cost-audit
# Prompts for Access Key ID, Secret Key, region (use us-east-1), output format
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

See [`minimal-iam-policy.md`](.claude/skills/aws-auth-setup/references/minimal-iam-policy.md) for a per-permission rationale you can show your security team.

---

## Verify the installation

**1. Check credentials and permissions:**

```bash
bash .claude/skills/aws-auth-setup/scripts/verify-creds.sh --profile cost-audit
```

Expected: JSON with `permission_probe` showing `"ok"` for `cost-explorer`, `ec2`, and `resource-tagging`.

**2. Run a cheap snapshot (~$0.07):**

```bash
bash .claude/skills/aws-cost-snapshot/scripts/snapshot.sh \
  --profile cost-audit --human
```

**3. Run a free waste scan:**

```bash
bash .claude/skills/aws-waste-hunter/scripts/run-all.sh \
  --profile cost-audit --human
```

---

## Prompts to try

| Ask your agent | Skill invoked |
|---|---|
| "Set up AWS credentials for a cost audit" | `aws-auth-setup` |
| "What are we spending on AWS?" / "Show me a cost overview" | `aws-cost-snapshot` |
| "Why is EC2 so expensive?" / "Drill into RDS costs" | `aws-cost-deep-dive` |
| "Find wasted resources" / "What can I delete?" | `aws-waste-hunter` |
| "What should I rightsize?" / "Savings Plan recommendations" | `aws-cost-optimizer` |
| "Any cost anomalies?" / "Why did the bill spike?" | `aws-cost-anomalies` |
| "Why is data transfer so high?" / "NAT Gateway costs" | `aws-data-transfer-profiler` |
| "Check tag coverage" / "Untagged spend" | `aws-tagging-audit` |
| "Audit my AWS costs" / "Full FinOps review" | `aws-cost-audit` (orchestrator) |

---

## Repo layout

```
aws-cost-auditor/
├── plugin.json                    # Universal plugin manifest
├── gemini-extension.json          # Gemini CLI extension config
├── .claude-plugin/plugin.json     # Claude Code plugin config
├── .cursor-plugin/plugin.json     # Cursor plugin config
├── README.md, CLAUDE.md, AGENTS.md, .gitignore
├── .claude/
│   ├── settings.json              # Read-only aws.* allowlist; writes denied
│   └── skills/
│       ├── aws-auth-setup/        # SKILL.md + scripts/ + references/
│       ├── aws-cost-snapshot/     # SKILL.md + scripts/
│       ├── aws-cost-deep-dive/    # SKILL.md + scripts/ + references/
│       ├── aws-waste-hunter/      # SKILL.md + scripts/ (10 scanners) + references/
│       ├── aws-cost-optimizer/    # SKILL.md + scripts/ (5) + references/
│       ├── aws-cost-anomalies/    # SKILL.md + scripts/
│       ├── aws-data-transfer-profiler/ # SKILL.md + scripts/ + references/
│       ├── aws-tagging-audit/     # SKILL.md + scripts/
│       └── aws-cost-audit/        # SKILL.md + scripts/ (orchestrator)
└── reports/                       # Audit output (gitignored)
```

---

## Safety model

Read-only is enforced at three independent layers:

1. **IAM policy** — no `*:Create*`, `*:Put*`, `*:Modify*`, `*:Delete*` etc.
2. **`.claude/settings.json`** — explicit `deny` list for any mutating `aws` verb.
3. **`CLAUDE.md` / `AGENTS.md`** — hard rule telling the agent never to propose write operations.

No data leaves AWS. Scripts write only to the local `reports/` directory (gitignored). Cost Explorer charges are gated — each stage prints estimated spend and asks before proceeding. `--yes` / `--all` override for scripted use.

---

## Roadmap

- [ ] CUR 2.0 parquet-on-S3 analysis for line-item-grade resolution
- [ ] HTML report with inline charts (currently markdown + JSON)
- [ ] Multi-account fan-out (assume-role across an Organization)
- [ ] "What changed since last run?" — diff two audit reports
- [ ] `aws-cdk-validator` skill: scan CDK/Terraform plans for cost-inefficient patterns before merge
- [ ] Native ports to Codex / Factory Droid / OpenCode skill formats

Open an issue or PR if you want one of these sooner.

---

## Contributing

Skills are intentionally small and focused — one concern per skill. To add one:

1. Create `.claude/skills/<name>/` with `SKILL.md` (YAML frontmatter: `name:`, `description:`, `license:`, and `metadata:` are mandatory).
2. Scripts go under `scripts/`; references under `references/`.
3. Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, a usage block, support for `--profile` and `--output-dir`, and never mutate AWS state.
4. The `description` field should name what the skill covers and when to use it — that drives auto-invocation in Claude Code and compatible agents.

See `CLAUDE.md` for the full project rules.

---

## License

MIT. See [`LICENSE`](LICENSE).
