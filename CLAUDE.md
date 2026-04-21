# AWS Cost Auditor — project rules

This repo is a Claude Code skill pack for auditing AWS costs. When the user
asks about AWS bills, spend, waste, or optimization, you should use the
skills under `.claude/skills/`.

## Hard rules

1. **Read-only, always.** Never suggest or run `aws` commands that mutate
   state (`create-*`, `delete-*`, `put-*`, `modify-*`, `terminate-*`,
   `stop-*`, `start-*`, `tag-resources`, `untag-resources`). The audit
   account is presumed to have read-only IAM anyway, but do not try to
   work around that.

2. **Verify creds before anything else.** Every skill must confirm
   `aws sts get-caller-identity` succeeds on the chosen profile before
   making other calls. If it fails, route the user to `aws-auth-setup`.

3. **Warn before Cost Explorer fan-outs.** Each `ce:Get*` call is $0.01.
   If a single skill run will issue more than ~10 CE calls, tell the user
   the estimated spend and ask before proceeding. Hourly-granularity
   requests cost extra ($0.00000033 per usage record) — always confirm.

4. **Quote the actual CLI command.** When reporting a finding, cite the
   exact `aws ...` call that produced it (or a script path) so the user
   can reproduce the number themselves. No opaque "the skill says X."

5. **Don't invent dollar amounts.** If a signal doesn't come with a cost
   attached (e.g., waste-hunter sees an orphaned EBS volume), use AWS's
   published list prices and say "list price, excluding any discount."
   Never guess blended rates.

6. **Use the skills as building blocks.** Prefer orchestrating the
   existing scripts over writing inline shell one-liners. If something
   is missing, add a new script to the relevant skill rather than
   running raw CLI in conversation.

## Profile handling

Default profile name is `cost-audit`. All scripts accept a `--profile <name>`
arg and fall back to `$AWS_PROFILE`, then to `default`. SSO profiles work the
same way — `aws sso login --profile <name>` first, then call the script.

## Report output

Long-form audit output goes into `reports/YYYY-MM-DD-<skill>.md` (and
optional `.json` for the raw data). This directory is gitignored.

## When adding a new skill

- Put it under `.claude/skills/<name>/SKILL.md` with YAML frontmatter:
  `name:` and `description:` are mandatory.
- Description must be specific enough that Claude Code auto-invokes it at
  the right moments — say *what the skill covers* and *when to use it*.
- Scripts live in `scripts/`, references in `references/`.
- Every script must be `chmod +x` and start with `#!/usr/bin/env bash`,
  `set -euo pipefail`, and a short usage block.
