#!/usr/bin/env bash
# Setup AWS CLI + test Bedrock for cloud-agent (standard boto3 SigV4).
#
# Usage:
#   ./scripts/setup-aws.sh              # full interactive setup
#   ./scripts/setup-aws.sh configure    # aws configure only
#   ./scripts/setup-aws.sh role         # add assume-role profile
#   ./scripts/setup-aws.sh verify       # check identity + bedrock
#   ./scripts/setup-aws.sh test         # run debug_bedrock.py
#
# Prerequisites: aws CLI v2, python3 venv in project root

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
MODEL_ID="${BEDROCK_MODEL_ID:-amazon.nova-micro-v1:0}"
PROFILE="${AWS_PROFILE:-default}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_aws() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  aws --version
}

require_venv() {
  [[ -f "$ROOT/.venv/bin/activate" ]] || die "Run first: python3 -m venv .venv && pip3 install -r requirements.txt"
}

step_configure() {
  log "Step 1: aws configure (standard access keys)"
  echo "You'll be prompted for:"
  echo "  - AWS Access Key ID"
  echo "  - AWS Secret Access Key"
  echo "  - Default region (use: $REGION)"
  echo "  - Default output format (use: json)"
  echo
  aws configure
}

step_configure_sso() {
  log "Step 1 (alt): aws configure sso"
  echo "Use this if your org uses AWS SSO / IAM Identity Center."
  echo
  aws configure sso
}

step_configure_role() {
  log "Step 2 (optional): add assume-role profile to ~/.aws/config"
  echo "Use this if you have staging keys that assume a Bedrock IAM role."
  echo

  read -r -p "Profile name [cloud-agent-bedrock]: " ROLE_PROFILE
  ROLE_PROFILE="${ROLE_PROFILE:-cloud-agent-bedrock}"

  read -r -p "Source profile (keys that can assume role) [default]: " SOURCE_PROFILE
  SOURCE_PROFILE="${SOURCE_PROFILE:-default}"

  read -r -p "Role ARN (arn:aws:iam::ACCOUNT:role/NAME): " ROLE_ARN
  [[ -n "$ROLE_ARN" ]] || die "Role ARN is required"

  read -r -p "Region [$REGION]: " INPUT_REGION
  INPUT_REGION="${INPUT_REGION:-$REGION}"

  mkdir -p "$HOME/.aws"
  touch "$HOME/.aws/config"

  if grep -q "\[profile $ROLE_PROFILE\]" "$HOME/.aws/config" 2>/dev/null; then
    die "Profile [$ROLE_PROFILE] already exists in ~/.aws/config — remove it first or pick another name"
  fi

  cat >> "$HOME/.aws/config" <<EOF

[profile $ROLE_PROFILE]
role_arn = $ROLE_ARN
source_profile = $SOURCE_PROFILE
region = $INPUT_REGION
EOF

  export AWS_PROFILE="$ROLE_PROFILE"
  PROFILE="$ROLE_PROFILE"

  log "Wrote profile [$ROLE_PROFILE] to ~/.aws/config"
  echo "Use it with: export AWS_PROFILE=$ROLE_PROFILE"
}

step_verify() {
  log "Verify AWS identity"
  export AWS_PROFILE="$PROFILE"
  export AWS_REGION="$REGION"
  aws sts get-caller-identity

  log "Check Bedrock Converse (SigV4) via AWS CLI"
  aws bedrock-runtime converse \
    --model-id "$MODEL_ID" \
    --region "$REGION" \
    --messages '[{"role":"user","content":[{"text":"Reply with exactly: ok"}]}]' \
    --inference-config '{"maxTokens":16,"temperature":0}' \
    --output json \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('Bedrock OK:', d['output']['message']['content'][0]['text'])"
}

write_env_file() {
  log "Write $ROOT/.env (no secrets — uses ~/.aws/credentials via AWS_PROFILE)"
  cat > "$ROOT/.env" <<EOF
# Standard boto3 SigV4 — credentials from: aws configure (or AWS_PROFILE below)
# Do NOT set AWS_BEARER_TOKEN_BEDROCK when using SigV4.

AWS_PROFILE=$PROFILE
AWS_REGION=$REGION

BEDROCK_MODEL_ID=$MODEL_ID
BEDROCK_MAX_TOKENS=256

# Direct Bedrock:
# BEDROCK_ENDPOINT_URL=https://bedrock-runtime.$REGION.amazonaws.com

# Via Akto proxy (client changes only this):
# BEDROCK_ENDPOINT_URL=https://akto-proxy?openai_url=https://bedrock-runtime.$REGION.amazonaws.com

LLM_TIMEOUT_SECONDS=90
PORT=8000
EOF
  echo "Wrote .env"
}

step_test_agent() {
  require_venv
  log "Test agent (boto3 wire headers + Converse call)"
  cd "$ROOT"
  # shellcheck disable=SC1091
  source .venv/bin/activate
  export AWS_PROFILE="$PROFILE"
  export AWS_REGION="$REGION"
  unset AWS_BEARER_TOKEN_BEDROCK || true
  "$ROOT/.venv/bin/python" debug_bedrock.py
}

step_test_proxy() {
  require_venv
  log "Test via Akto proxy"
  cd "$ROOT"
  # shellcheck disable=SC1091
  source .venv/bin/activate
  export AWS_PROFILE="$PROFILE"
  export AWS_REGION="$REGION"
  unset AWS_BEARER_TOKEN_BEDROCK || true
  unset BEDROCK_ENDPOINT_URL || true
  "$ROOT/.venv/bin/python" debug_bedrock.py
}

print_iam_policy() {
  log "IAM policy reference (attach to your user/role in AWS console or CLI)"
  cat <<'EOF'

Minimum Bedrock permissions for this agent:

{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockConverse",
      "Effect": "Allow",
      "Action": [
        "bedrock:Converse",
        "bedrock:ConverseStream"
      ],
      "Resource": "*"
    }
  ]
}

If using assume-role, staging user also needs:

{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME"
    }
  ]
}

Bedrock console: enable model access for your chosen model in $REGION.

EOF
}

full_setup() {
  require_aws
  echo "cloud-agent AWS setup"
  echo "---------------------"
  echo "1) Standard access keys (aws configure)"
  echo "2) SSO (aws configure sso)"
  read -r -p "Choice [1]: " AUTH_CHOICE
  AUTH_CHOICE="${AUTH_CHOICE:-1}"

  case "$AUTH_CHOICE" in
    1) step_configure ;;
    2) step_configure_sso ;;
    *) die "Invalid choice" ;;
  esac

  read -r -p "Do you need an assume-role profile? [y/N]: " NEED_ROLE
  if [[ "$NEED_ROLE" == [yY] ]]; then
    step_configure_role
  fi

  step_verify
  write_env_file
  step_test_agent

  read -r -p "Also test Akto proxy? [y/N]: " TEST_PROXY
  if [[ "$TEST_PROXY" == [yY] ]]; then
    step_test_proxy
  fi

  print_iam_policy
  log "Done. Run: python3 agent.py"
}

CMD="${1:-all}"
case "$CMD" in
  all|"")       full_setup ;;
  configure)    require_aws; step_configure ;;
  sso)          require_aws; step_configure_sso ;;
  role)         require_aws; step_configure_role ;;
  verify)       require_aws; step_verify ;;
  env)          write_env_file ;;
  test)         require_aws; step_test_agent ;;
  test-proxy)   require_aws; step_test_proxy ;;
  policy)       print_iam_policy ;;
  *)
    echo "Usage: $0 [all|configure|sso|role|verify|env|test|test-proxy|policy]"
    exit 1
    ;;
esac
