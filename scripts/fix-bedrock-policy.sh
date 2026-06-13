#!/usr/bin/env bash
# Fix Bedrock IAM policy on cloud-agent-bedrock role (run if Converse fails with AccessDenied).
#
# Usage:
#   ./scripts/fix-bedrock-policy.sh

set -euo pipefail

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"
REGION="${AWS_REGION:-us-east-1}"
POLICY_NAME="${POLICY_NAME:-CloudAgentBedrockPolicy}"
ROLE_NAME="${ROLE_NAME:-cloud-agent-bedrock}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_FILE="$ROOT/scripts/policies/bedrock-policy.json"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$POLICY_FILE" ]] || die "Missing $POLICY_FILE"

[[ -n "$ACCOUNT_ID" ]] || die "No AWS credentials. Run: aws configure (or set ACCOUNT_ID)"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

log "Create or update IAM policy: $POLICY_NAME"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  VERSIONS="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
  for v in $VERSIONS; do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v" 2>/dev/null || true
  done
  aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "file://$POLICY_FILE" \
    --set-as-default
  echo "Updated policy: $POLICY_ARN"
else
  POLICY_ARN="$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$POLICY_FILE" \
    --description "Bedrock Converse + inference profile access for cloud-agent" \
    --query Policy.Arn --output text)"
  echo "Created policy: $POLICY_ARN"
fi

log "Attach policy to role: $ROLE_NAME"
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null \
  || echo "(already attached)"

log "Wait for IAM propagation (10s)"
sleep 10

log "Verify role policies"
aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output table

log "Test Bedrock Converse (assumed role)"
export AWS_PROFILE="${AWS_PROFILE:-cloud-agent-bedrock}"
export AWS_REGION="$REGION"
MODEL_ID="${BEDROCK_MODEL_ID:-amazon.nova-micro-v1:0}"

aws sts get-caller-identity

if aws bedrock-runtime converse \
  --model-id "$MODEL_ID" \
  --region "$REGION" \
  --messages '[{"role":"user","content":[{"text":"Reply with exactly: ok"}]}]' \
  --inference-config '{"maxTokens":16,"temperature":0}' \
  --output json > /tmp/converse-out.json 2>/tmp/converse-err.txt; then
  python3 -c "import json; d=json.load(open('/tmp/converse-out.json')); print('SUCCESS:', d['output']['message']['content'][0]['text'])"
  echo
  echo "Bedrock access fixed."
else
  cat /tmp/converse-err.txt >&2
  die "Bedrock test still failing — check role trust policy and AWS_PROFILE"
fi
