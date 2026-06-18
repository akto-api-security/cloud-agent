#!/usr/bin/env bash
# Bootstrap ALL AWS resources for cloud-agent from a fresh account.
#
# Prerequisites:
#   - aws CLI v2 installed
#   - Admin/root credentials configured (aws configure) for your AWS account
#
# Usage:
#   aws configure          # login with your admin keys first
#   ./scripts/bootstrap-account.sh
#
# Creates:
#   - IAM managed policy: CloudAgentBedrockPolicy
#   - IAM user:           cloud-agent-staging
#   - IAM role:           cloud-agent-bedrock
#   - Access key for staging user
#   - AWS CLI profiles in ~/.aws/credentials and ~/.aws/config
#   - cloud-agent/.env
#
# Then tests Bedrock Converse (SigV4 via assume-role).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- defaults (override via env) ---
ACCOUNT_ID="${ACCOUNT_ID:-}"
REGION="${AWS_REGION:-us-east-1}"
MODEL_ID="${BEDROCK_MODEL_ID:-amazon.nova-micro-v1:0}"

USER_NAME="${USER_NAME:-cloud-agent-staging}"
ROLE_NAME="${ROLE_NAME:-cloud-agent-bedrock}"
POLICY_NAME="${POLICY_NAME:-CloudAgentBedrockPolicy}"

PROFILE_STAGING="${PROFILE_STAGING:-cloud-agent-staging}"
PROFILE_BEDROCK="${PROFILE_BEDROCK:-cloud-agent-bedrock}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

tmpdir() { mktemp -d "${TMPDIR:-/tmp}/cloud-agent-bootstrap.XXXXXX"; }
WORK="$(tmpdir)"
trap 'rm -rf "$WORK"' EXIT

require_aws() {
  command -v aws >/dev/null 2>&1 || die "Install AWS CLI v2 first"
  aws --version
}

current_account() {
  aws sts get-caller-identity --query Account --output text 2>/dev/null || echo ""
}

policy_arn() {
  local arn
  arn="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" --output text 2>/dev/null || true)"
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    echo ""
  else
    echo "$arn"
  fi
}

user_exists() {
  aws iam get-user --user-name "$USER_NAME" >/dev/null 2>&1
}

role_exists() {
  aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1
}

step_preflight() {
  log "Preflight checks"
  require_aws

  CALLER_ACCOUNT="$(current_account)"
  [[ -n "$CALLER_ACCOUNT" ]] || die "No AWS credentials. Run: aws configure"

  ACCOUNT_ID="${ACCOUNT_ID:-$CALLER_ACCOUNT}"

  echo "Caller account: $CALLER_ACCOUNT"
  echo "Target account: $ACCOUNT_ID"
  echo "Region:         $REGION"
  echo "Model:          $MODEL_ID"

  if [[ "$CALLER_ACCOUNT" != "$ACCOUNT_ID" ]]; then
    warn "Caller account ($CALLER_ACCOUNT) != ACCOUNT_ID ($ACCOUNT_ID). Continuing anyway."
  fi

  aws sts get-caller-identity
}

step_create_bedrock_policy() {
  log "Create IAM managed policy: $POLICY_NAME"

  EXISTING="$(policy_arn)"
  if [[ -n "$EXISTING" ]]; then
    echo "Policy already exists: $EXISTING"
    POLICY_ARN="$EXISTING"
    return
  fi

  cat > "$WORK/bedrock-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInvokeAndConverse",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
        "bedrock:ConverseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*",
        "arn:aws:bedrock:*:*:application-inference-profile/*"
      ]
    },
    {
      "Sid": "BedrockReadModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel",
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": "*"
    }
  ]
}
EOF

  POLICY_ARN="$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$WORK/bedrock-policy.json" \
    --description "Bedrock Converse access for cloud-agent" \
    --query Policy.Arn --output text)"
  echo "Created policy: $POLICY_ARN"
}

step_create_staging_user() {
  log "Create IAM user: $USER_NAME"

  if user_exists; then
    echo "User already exists: $USER_NAME"
  else
    aws iam create-user \
      --user-name "$USER_NAME" \
      --tags Key=Project,Value=cloud-agent
    echo "Created user: $USER_NAME"
  fi

  # IAM needs a moment before the user ARN is valid in trust policies.
  aws iam wait user-exists --user-name "$USER_NAME"
  USER_ARN="$(aws iam get-user --user-name "$USER_NAME" --query User.Arn --output text)"
  echo "User ARN: $USER_ARN"
}

step_create_bedrock_role() {
  log "Create IAM role: $ROLE_NAME"

  if [[ -z "${USER_ARN:-}" ]]; then
    USER_ARN="$(aws iam get-user --user-name "$USER_NAME" --query User.Arn --output text)"
  fi

  cat > "$WORK/trust-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "$USER_ARN" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  if role_exists; then
    echo "Role already exists: $ROLE_NAME"
    aws iam update-assume-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-document "file://$WORK/trust-policy.json"
    echo "Updated trust policy for: $ROLE_NAME"
  else
    local attempt=1
    local max_attempts=5
    while [[ $attempt -le $max_attempts ]]; do
      if aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$WORK/trust-policy.json" \
        --description "Bedrock role for cloud-agent (assumed by $USER_NAME)" 2>"$WORK/create-role.err"; then
        echo "Created role: $ROLE_NAME"
        break
      fi
      if grep -q "MalformedPolicyDocument\|Invalid principal" "$WORK/create-role.err" && [[ $attempt -lt $max_attempts ]]; then
        warn "Role create attempt $attempt failed (IAM propagation?). Retrying in 5s..."
        sleep 5
        attempt=$((attempt + 1))
      else
        cat "$WORK/create-role.err" >&2
        die "Failed to create role $ROLE_NAME"
      fi
    done
  fi

  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

  log "Attach Bedrock policy to role"
  [[ -n "${POLICY_ARN:-}" ]] || die "POLICY_ARN is unset — policy step failed"
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN" 2>/dev/null || echo "(policy may already be attached)"
}

step_grant_user_assume_role() {
  log "Grant $USER_NAME permission to assume $ROLE_NAME"

  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

  cat > "$WORK/assume-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "$ROLE_ARN"
    }
  ]
}
EOF

  aws iam put-user-policy \
    --user-name "$USER_NAME" \
    --policy-name "${ROLE_NAME}-assume" \
    --policy-document "file://$WORK/assume-policy.json"
}

step_create_access_key() {
  log "Create access key for $USER_NAME"

  EXISTING_COUNT="$(aws iam list-access-keys --user-name "$USER_NAME" --query 'length(AccessKeyMetadata)' --output text)"
  if [[ "$EXISTING_COUNT" -ge 2 ]]; then
    die "User $USER_NAME already has 2 access keys. Delete one in IAM console and re-run."
  fi

  if [[ "$EXISTING_COUNT" -ge 1 ]]; then
    warn "User already has an access key. Creating a second one (max 2)."
    read -r -p "Continue? [y/N]: " CONFIRM
    [[ "$CONFIRM" == [yY] ]] || die "Aborted. Use existing key with: aws configure --profile $PROFILE_STAGING"
  fi

  KEY_JSON="$(aws iam create-access-key --user-name "$USER_NAME" --output json)"
  ACCESS_KEY_ID="$(echo "$KEY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")"
  SECRET_ACCESS_KEY="$(echo "$KEY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")"

  echo
  echo "========== SAVE THESE (shown once) =========="
  echo "AWS_ACCESS_KEY_ID=$ACCESS_KEY_ID"
  echo "AWS_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY"
  echo "============================================="
  echo
}

step_configure_aws_cli() {
  log "Configure AWS CLI profiles"

  mkdir -p "$HOME/.aws"
  touch "$HOME/.aws/credentials" "$HOME/.aws/config"

  aws configure set aws_access_key_id "$ACCESS_KEY_ID" --profile "$PROFILE_STAGING"
  aws configure set aws_secret_access_key "$SECRET_ACCESS_KEY" --profile "$PROFILE_STAGING"
  aws configure set region "$REGION" --profile "$PROFILE_STAGING"
  aws configure set output json --profile "$PROFILE_STAGING"

  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

  if ! grep -q "\[profile $PROFILE_BEDROCK\]" "$HOME/.aws/config" 2>/dev/null; then
    cat >> "$HOME/.aws/config" <<EOF

[profile $PROFILE_BEDROCK]
role_arn = $ROLE_ARN
source_profile = $PROFILE_STAGING
region = $REGION
output = json
EOF
    echo "Added profile [$PROFILE_BEDROCK] to ~/.aws/config"
  else
    warn "Profile [$PROFILE_BEDROCK] already in ~/.aws/config — skipping"
  fi

  echo "Profiles ready:"
  echo "  $PROFILE_STAGING  (staging keys)"
  echo "  $PROFILE_BEDROCK    (assumes role → Bedrock)"
}

step_bedrock_console_note() {
  log "Bedrock model access"
  cat <<EOF

AWS retired the manual "Model access" page — serverless models are enabled
automatically on first use. Access is controlled via IAM policies (this script).

No console step needed. Press Enter to test Bedrock...
EOF
  read -r _
}

step_verify_bedrock() {
  log "Verify Bedrock Converse (SigV4 via assume-role)"

  export AWS_PROFILE="$PROFILE_BEDROCK"
  export AWS_REGION="$REGION"

  echo "Identity (should show assumed role):"
  aws sts get-caller-identity

  echo
  echo "Listing inference profiles in $REGION..."
  aws bedrock list-inference-profiles --region "$REGION" --type-equals SYSTEM_DEFINED \
    --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'nova')].inferenceProfileId" \
    --output table 2>/dev/null || warn "Could not list inference profiles (may need model access enabled)"

  log "Wait for IAM propagation (10s)"
  sleep 10

  log "Bedrock Converse smoke test"
  if ! aws bedrock-runtime converse \
    --model-id "$MODEL_ID" \
    --region "$REGION" \
    --messages '[{"role":"user","content":[{"text":"Reply with exactly: ok"}]}]' \
    --inference-config '{"maxTokens":16,"temperature":0}' \
    --output json > "$WORK/converse.json" 2>"$WORK/converse.err"; then
    cat "$WORK/converse.err" >&2
    warn "Bedrock test failed. Run: ./scripts/fix-bedrock-policy.sh"
    return 1
  fi
  python3 -c "import json; d=json.load(open('$WORK/converse.json')); print('SUCCESS:', d['output']['message']['content'][0]['text'])"
}

step_write_env() {
  log "Write $ROOT/.env"

  cat > "$ROOT/.env" <<EOF
# Standard boto3 SigV4 via assume-role profile (created by bootstrap-account.sh)
AWS_PROFILE=$PROFILE_BEDROCK
AWS_REGION=$REGION

# Do NOT set AWS_BEARER_TOKEN_BEDROCK when using SigV4

BEDROCK_MODEL_ID=$MODEL_ID
BEDROCK_MAX_TOKENS=256

# Direct Bedrock:
# BEDROCK_ENDPOINT_URL=https://bedrock-runtime.$REGION.amazonaws.com

# Via Akto proxy (client changes only this):
# BEDROCK_ENDPOINT_URL=https://akto-proxy?openai_url=https://bedrock-runtime.$REGION.amazonaws.com

LLM_TIMEOUT_SECONDS=90
PORT=8000
EOF
}

step_test_agent() {
  if [[ ! -f "$ROOT/.venv/bin/activate" ]]; then
    warn "Python venv not found. Run: python3 -m venv .venv && pip3 install -r requirements.txt"
    return
  fi

  log "Test cloud-agent (boto3 Converse smoke test)"
  cd "$ROOT"
  # shellcheck disable=SC1091
  source .venv/bin/activate
  export AWS_PROFILE="$PROFILE_BEDROCK"
  export AWS_REGION="$REGION"
  unset AWS_BEARER_TOKEN_BEDROCK BEDROCK_ENDPOINT_URL || true
  "$ROOT/.venv/bin/python" - <<'PY'
from bedrock_config import create_bedrock_runtime_client, default_model_id
import os

client = create_bedrock_runtime_client()
model_id = os.getenv("BEDROCK_MODEL_ID", "").strip() or default_model_id()
response = client.converse(
    modelId=model_id,
    messages=[{"role": "user", "content": [{"text": "Reply with exactly: ok"}]}],
    inferenceConfig={"maxTokens": 16, "temperature": 0},
)
print("SUCCESS:", response["output"]["message"]["content"][0]["text"])
PY
}

print_summary() {
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
  cat <<EOF

========================================
Bootstrap complete
========================================
Account:  $ACCOUNT_ID
Region:   $REGION
Model:    $MODEL_ID

IAM user:  $USER_NAME
IAM role:  $ROLE_NAME
Role ARN:  $ROLE_ARN

AWS CLI profiles:
  export AWS_PROFILE=$PROFILE_BEDROCK    # use this for cloud-agent

Next:
  source .venv/bin/activate
  python3 agent.py
  ./scripts/test-curl.sh chat
  ./scripts/setup-aws.sh test-proxy       # test Akto proxy (set BEDROCK_ENDPOINT_URL first)

========================================
EOF
}

main() {
  echo "cloud-agent AWS bootstrap"
  echo "Account $ACCOUNT_ID | Region $REGION"
  echo
  read -r -p "This creates IAM user/role/policy. Continue? [y/N]: " GO
  [[ "$GO" == [yY] ]] || exit 0

  step_preflight
  step_create_bedrock_policy
  step_create_staging_user
  step_create_bedrock_role
  step_grant_user_assume_role
  step_create_access_key
  step_configure_aws_cli
  step_bedrock_console_note
  step_verify_bedrock
  step_write_env
  step_test_agent
  print_summary
}

main "$@"
