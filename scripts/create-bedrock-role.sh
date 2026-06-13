#!/usr/bin/env bash
# Optional: create IAM role + policy for Bedrock (requires admin credentials).
#
# Usage:
#   ./scripts/create-bedrock-role.sh
#
# You will be prompted for account/role names. Run once per AWS account.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "aws CLI required"

read -r -p "IAM role name [cloud-agent-bedrock]: " ROLE_NAME
ROLE_NAME="${ROLE_NAME:-cloud-agent-bedrock}"

read -r -p "Staging IAM user ARN (trust principal): " USER_ARN
[[ -n "$USER_ARN" ]] || die "User ARN required, e.g. arn:aws:iam::123456789012:user/staging"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
POLICY_NAME="${ROLE_NAME}-bedrock-policy"

TRUST_FILE="$(mktemp)"
POLICY_FILE="$(mktemp)"
trap 'rm -f "$TRUST_FILE" "$POLICY_FILE"' EXIT

cat > "$TRUST_FILE" <<EOF
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

cat > "$POLICY_FILE" <<EOF
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
EOF

log "Create role $ROLE_NAME"
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "file://$TRUST_FILE" \
  --description "Bedrock Converse access for cloud-agent" \
  2>/dev/null || echo "(role may already exist)"

log "Attach inline Bedrock policy"
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://$POLICY_FILE"

log "Grant staging user permission to assume role"
read -r -p "Staging user name (for sts:AssumeRole policy) [skip]: " STAGING_USER
if [[ -n "$STAGING_USER" ]]; then
  ASSUME_POLICY="$(mktemp)"
  cat > "$ASSUME_POLICY" <<EOF
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
    --user-name "$STAGING_USER" \
    --policy-name "${ROLE_NAME}-assume" \
    --policy-document "file://$ASSUME_POLICY"
  rm -f "$ASSUME_POLICY"
fi

cat <<EOF

Created:
  Role ARN:  $ROLE_ARN
  Region:    $REGION

Next:
  1. Enable Bedrock model access in console for your model in $REGION
  2. Run: ./scripts/setup-aws.sh role
     Role ARN: $ROLE_ARN
  3. Run: ./scripts/setup-aws.sh verify

EOF
