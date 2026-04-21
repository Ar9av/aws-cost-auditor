# AGENTS.md — portability shim

This repo is primarily a **Claude Code** skill pack, but the underlying
scripts in `.claude/skills/<skill>/scripts/` are plain bash and work from
any agent runtime that can execute shell commands.

If you are an agent other than Claude Code (Codex, Factory Droid, OpenCode,
Copilot CLI, Gemini CLI, etc.), read this file as the project-level
instructions.

## How to use this repo

1. Read `.claude/skills/<skill-name>/SKILL.md` for each skill — it has
   YAML frontmatter (`name`, `description`) and prose describing when and
   how to use the scripts.
2. To run a script: `bash .claude/skills/<skill>/scripts/<name>.sh --profile <aws_profile>`
3. Credential setup lives in `aws-auth-setup`. Run that first if
   `aws sts get-caller-identity` fails.
4. Hard rules are in `CLAUDE.md` (they apply regardless of agent — most
   importantly: **read-only AWS calls only**).

## Quick map

| Want to… | Skill |
|---|---|
| Set up creds | `aws-auth-setup` |
| Get a spend overview | `aws-cost-snapshot` |
| Drill into a specific service | `aws-cost-deep-dive` |
| Find orphaned / idle resources | `aws-waste-hunter` |
| Get rightsizing recs | `aws-cost-optimizer` |
| Check for cost spikes | `aws-cost-anomalies` |
| Investigate networking spend | `aws-data-transfer-profiler` |
| Check tagging hygiene | `aws-tagging-audit` |
| Run everything end-to-end | `aws-cost-audit` |

## Conventions

- Scripts output JSON by default and pretty-print with `--human`.
- All scripts accept `--profile`, `--region`, and `--output-dir`.
- Nothing mutates AWS state. Nothing writes outside `reports/`.
