---
name: aws-tagging-audit
description: Measure AWS cost-allocation tag hygiene. Surfaces share of spend that lacks required tags, which cost allocation tags are activated vs inactive, which resource types are worst-tagged, and the biggest untagged cost offenders. Use this skill when the user asks about "tagging", "untagged resources", "cost allocation tags", "chargeback", "showback", or when they need tag-based budget filtering to work.
---

# aws-tagging-audit

You can't do chargeback / showback / per-team budgets if your bill isn't
tagged. This skill answers two questions:

1. **What share of spend is currently tagged?** (and with which keys)
2. **Which resources are the biggest untagged offenders?**

## When to invoke

- User asks "how well tagged are we?", "cost allocation", "chargeback",
  "untagged resources", "tag compliance".
- After `aws-cost-snapshot` — if the user wants per-team or per-project
  attribution and tags aren't active, tell them.
- Before setting up budgets / Cost Explorer filters based on tags.

## What it does

### Step 1: Which cost allocation tags are active?

`ce:ListCostAllocationTags` shows every tag key, whether it's activated
for cost allocation, and whether it's user-defined or AWS-generated.
Only activated keys can be used for filtering and grouping in Cost
Explorer, Budgets, and CUR.

### Step 2: What share of spend has each key set?

For each activated key, runs a `GetCostAndUsage` grouped by that tag and
calculates what share of total cost has any value set vs. blank. Report
the offenders (spend with key unset).

### Step 3: Which resources are untagged?

Uses `tag:GetResources` with no tag filter to enumerate every taggable
resource, then flags the ones without the user's *required* keys. User
passes `--required <key1,key2>` — defaults to `Project,Environment,Owner`.

## Cost

- 1 CE call for list (free).
- N CE calls for grouping by each required key = $0.01 × N.
- `tag:GetResources` is free.

Total typical: **$0.03-0.05** for 3 required keys.

## How to run

```bash
# Default required keys: Project, Environment, Owner
bash .claude/skills/aws-tagging-audit/scripts/tagging-audit.sh \
  --profile cost-audit

# Custom required keys + longer window
bash .claude/skills/aws-tagging-audit/scripts/tagging-audit.sh \
  --profile cost-audit \
  --required "team,service,env,cost-center" \
  --days 60
```

## Output

```json
{
  "required_keys": ["Project", "Environment", "Owner"],
  "period": { "start": "...", "end": "..." },
  "cost_allocation_tags": [
    { "key": "Project", "status": "Active", "type": "UserDefined" },
    { "key": "Environment", "status": "Inactive", "type": "UserDefined" }
  ],
  "coverage_by_key": [
    { "key": "Project", "covered_pct": 78.4, "untagged_amount": 2480.00, "total": 11480.00 }
  ],
  "untagged_resources": [
    { "resource_arn": "...", "service": "ec2", "region": "us-east-1",
      "missing_keys": ["Owner"], "existing_tags": {"Project": "backend"} }
  ],
  "gaps": {
    "inactive_required_keys": ["Environment"],
    "total_untagged_resources": 412,
    "estimated_untagged_monthly_cost_usd": 4250.00
  }
}
```

## Interpreting

- **Required key not active for cost allocation** → single biggest fix.
  Activate in Billing console → Cost allocation tags → pick key → Activate.
  (Requires write permission, which this skill doesn't have.)
- **Low coverage on active key** → governance gap. Tag Policies or
  Service Control Policies can enforce tag-on-create.
- **Hot untagged resources** → manual sprint to backfill tags on the
  top N spenders often recovers most of the attribution gap.

## Reference

- Tag activation in the Billing console takes effect within 24-48h for
  Cost Explorer and CUR — don't expect instant results.
- AWS-generated tags (like `aws:createdBy`) are always present but must
  also be activated.
- Some resource types (Route 53 hosted zones, IAM users, some Lambda
  configurations) aren't taggable at all — they'll show up as
  "untaggable" in the report, not as violations.
