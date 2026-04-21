#!/usr/bin/env bash
#
# compute-optimizer.sh — pull rightsizing recommendations from Compute Optimizer.
#
# Usage: compute-optimizer.sh [--profile <p>]
#                             [--resource-type Ec2Instance|EbsVolume|LambdaFunction|EcsService|AutoScalingGroup|RdsDbInstance]
#                             [--region <r>] [--output-dir <path>] [--human]
#
# If --resource-type not set, runs all. Compute Optimizer is free and regional
# (recommendations live in each region's service endpoint).

set -euo pipefail

PROFILE=""
REGION=""
RTYPE=""
OUT_DIR="reports"
HUMAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)       PROFILE="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --resource-type) RTYPE="$2"; shift 2 ;;
    --output-dir)    OUT_DIR="$2"; shift 2 ;;
    --human)         HUMAN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
TS=$(date -u +%Y-%m-%d)
OUT_JSON="$OUT_DIR/$TS-compute-optimizer.json"

aws_() {
  local args=()
  [[ -n "$PROFILE" ]] && args+=(--profile "$PROFILE")
  [[ -n "$REGION"  ]] && args+=(--region "$REGION")
  aws "${args[@]}" --output json "$@"
}

# Enrollment check
enroll=$(aws_ compute-optimizer get-enrollment-status 2>&1 || echo "__err__")
status=$(jq -r '.status // "Inactive"' <<<"$enroll" 2>/dev/null || echo "Inactive")

if [[ "$status" != "Active" ]]; then
  jq -n --arg status "$status" \
    '{enrolled: false, status: $status, note: "Compute Optimizer not enrolled. Enrol via `aws compute-optimizer update-enrollment-status --status Active`. Needs ≥14d utilization metrics before recommendations appear."}' \
    | tee "$OUT_JSON"
  exit 0
fi

# Summary
summary=$(aws_ compute-optimizer get-recommendation-summaries 2>/dev/null || echo '{}')

result='{}'
add_block() {
  local name="$1" json="$2"
  result=$(jq --arg k "$name" --argjson v "$json" '. + {($k): $v}' <<<"$result")
}

pull() {
  local rt="$1" api_cmd="$2" parser="$3"
  echo "[+] Fetching $rt recommendations..." >&2
  local raw
  raw=$(aws_ compute-optimizer "$api_cmd" --max-results 200 2>/dev/null || echo '{}')
  jq "$parser" <<<"$raw"
}

ec2_parser='
{
  summary: {count: ((.instanceRecommendations // []) | length)},
  recommendations: ((.instanceRecommendations // []) | map({
    resource_id: .instanceArn,
    instance_name: .instanceName,
    current_type: .currentInstanceType,
    finding: .finding,
    findings_reasons: [.findingReasonCodes // [] | .[]],
    recommendations: [(.recommendationOptions // []) | .[] | {
      instance_type: .instanceType,
      migration_effort: .migrationEffort,
      performance_risk: .performanceRisk,
      projected_utilization: .projectedUtilizationMetrics,
      savings_opportunity: {
        monthly_pct: (.savingsOpportunity.savingsOpportunityPercentage // 0),
        monthly_amount: (.savingsOpportunity.estimatedMonthlySavings.value // 0),
        currency: (.savingsOpportunity.estimatedMonthlySavings.currency // "USD")
      }
    }]
  } | .top_recommendation = (.recommendations[0] // null)) | sort_by(-(.top_recommendation.savings_opportunity.monthly_amount // 0))
}
'

ebs_parser='
{
  summary: {count: ((.volumeRecommendations // []) | length)},
  recommendations: ((.volumeRecommendations // []) | map({
    volume_arn: .volumeArn,
    current: .currentConfiguration,
    finding: .finding,
    top_option: (.volumeRecommendationOptions[0] // null),
    estimated_monthly_savings: (.volumeRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // 0),
    savings_pct: (.volumeRecommendationOptions[0].savingsOpportunity.savingsOpportunityPercentage // 0)
  }) | sort_by(-.estimated_monthly_savings))
}
'

lambda_parser='
{
  summary: {count: ((.lambdaFunctionRecommendations // []) | length)},
  recommendations: ((.lambdaFunctionRecommendations // []) | map({
    function_arn: .functionArn,
    current_memory_mb: .currentMemorySize,
    finding: .finding,
    top_option: (.memorySizeRecommendationOptions[0] // null),
    estimated_monthly_savings: (.memorySizeRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // 0)
  }) | sort_by(-.estimated_monthly_savings))
}
'

rds_parser='
{
  summary: {count: ((.rdsDBRecommendations // []) | length)},
  recommendations: ((.rdsDBRecommendations // []) | map({
    db_arn: .resourceArn,
    finding: .finding,
    current: .currentDBInstanceClass,
    top_option: (.instanceRecommendationOptions[0] // null),
    estimated_monthly_savings: (.instanceRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // 0)
  }) | sort_by(-.estimated_monthly_savings))
}
'

asg_parser='
{
  summary: {count: ((.autoScalingGroupRecommendations // []) | length)},
  recommendations: ((.autoScalingGroupRecommendations // []) | map({
    asg_arn: .autoScalingGroupArn,
    finding: .finding,
    top_option: (.recommendationOptions[0] // null),
    estimated_monthly_savings: (.recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // 0)
  }) | sort_by(-.estimated_monthly_savings))
}
'

ecs_parser='
{
  summary: {count: ((.ecsServiceRecommendations // []) | length)},
  recommendations: ((.ecsServiceRecommendations // []) | map({
    service_arn: .serviceArn,
    finding: .finding,
    current_cpu: .currentServiceConfiguration.cpu,
    current_memory: .currentServiceConfiguration.memory,
    top_option: (.serviceRecommendationOptions[0] // null),
    estimated_monthly_savings: (.serviceRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // 0)
  }) | sort_by(-.estimated_monthly_savings))
}
'

run_type() {
  case "$1" in
    Ec2Instance)      add_block "ec2_instances" "$(pull ec2 get-ec2-instance-recommendations "$ec2_parser")" ;;
    EbsVolume)        add_block "ebs_volumes"   "$(pull ebs get-ebs-volume-recommendations "$ebs_parser")" ;;
    LambdaFunction)   add_block "lambda"        "$(pull lambda get-lambda-function-recommendations "$lambda_parser")" ;;
    RdsDbInstance)    add_block "rds"           "$(pull rds get-rds-database-recommendations "$rds_parser")" ;;
    AutoScalingGroup) add_block "asg"           "$(pull asg get-auto-scaling-group-recommendations "$asg_parser")" ;;
    EcsService)       add_block "ecs"           "$(pull ecs get-ecs-service-recommendations "$ecs_parser")" ;;
  esac
}

if [[ -n "$RTYPE" ]]; then
  run_type "$RTYPE"
else
  for t in Ec2Instance EbsVolume LambdaFunction RdsDbInstance AutoScalingGroup EcsService; do
    run_type "$t"
  done
fi

total_savings=$(jq '[.. | .estimated_monthly_savings? // empty] | add // 0' <<<"$result")

jq -n \
  --argjson summary "$summary" \
  --argjson result "$result" \
  --argjson total "$total_savings" \
  '{
    enrolled: true,
    summary: $summary,
    total_estimated_monthly_savings_usd: $total,
    by_resource_type: $result
  }' | tee "$OUT_JSON" >/dev/null

echo "Wrote $OUT_JSON  (total est. savings: \$$total_savings)" >&2
